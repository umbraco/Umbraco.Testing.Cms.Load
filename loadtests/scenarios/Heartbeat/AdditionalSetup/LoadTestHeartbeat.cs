// Diagnostic overlay for the Heartbeat scenario. Not part of the measured product.
//
// Frontend runs show whole-site pauses: for 6-20 s almost nothing is answered,
// requests pile up and then come out in a trickle, while Umbraco logs nothing
// and CPU, SQL DTU and the request queue look idle (builds 305559, 305676,
// 305703, 305770, 305781, 305823). The per-minute Azure Monitor metrics cannot
// tell a frozen process from a blocked thread pool from a hung file share from
// a slow or locked database.
//
// This hosted service beats once a second on its OWN thread (not a thread-pool
// thread, so a starved pool cannot delay it) and times these:
//
//   late_ms    how late the beat woke up. Large with gc_pause_ms large: the
//              garbage collector froze the process. Large with gc_pause_ms
//              small: the process was frozen or starved from outside.
//   pool_ms    how long a queued thread-pool work item waited to start. Large
//              while late_ms is small: the thread pool is starved (requests
//              are blocking its threads), the process itself is fine.
//              pool_threads and pool_pending are the pool's size and backlog.
//   share_ms   a small write to the site folder, which on App Service is a
//              remote file share. local_ms is the same write to local temp.
//   sql_ms     open a pooled connection and count the requests in the database
//              that are waiting on another session's lock (sql_blocked) and
//              the longest such wait (sql_blocked_wait_ms). Content writes
//              queueing on Umbraco's lock rows show here.
//   *_failed   the probe threw. Its _ms is then the time it took to fail.
//   gap_ms     time since the previous beat finished. The probes run on the
//              beat thread, so one that hangs stops the beats: the next line
//              then carries the length of the hang here.
//
// A small middleware at the front of the pipeline also counts requests, so a
// beat knows what the app itself saw:
//
//   in_flight  requests inside the app right now; started / completed are the
//              counts since the previous beat.
//   stuck_ms   with requests in flight, how long since any request completed.
//              Large with in_flight large and the probes above all normal:
//              requests are waiting inside the app on something that blocks
//              few or no threads (a lock, a cache rebuild).
//              in_flight 0 and started 0 while the load test was sending: the
//              requests never reached the app - the stall is in front of it
//              (App Service front end, network, or the load generator).
//
// EVERY beat is logged ("LoadTestHeartbeat beat"), as a Warning when something
// crossed its threshold or a probe failed and as Information otherwise, plus a
// one-line summary each minute. Read the lines for the seconds of a pause the
// publish step reports ("whole-site pause(s) ... at HH:mm:ss UTC") in
// umbraco/Logs/UmbracoTraceLog.*.json. The pipeline saves that file with the
// run (umbraco-logs/ in the build artifact and under raw/ in history storage).
//
// Uses only BCL, Microsoft.Extensions.*, Umbraco's IComposer and
// Microsoft.Data.SqlClient (a dependency of Umbraco's SQL Server provider).
// Compiled against Umbraco 17.8.2 (net10.0) and 19.0.0-rc1 (net11.0).
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Umbraco.Cms.Core.Composing;
using Umbraco.Cms.Core.DependencyInjection;

namespace LoadTestDiagnostics;

public sealed class LoadTestHeartbeatComposer : IComposer
{
    public void Compose(IUmbracoBuilder builder)
    {
        builder.Services.AddTransient<IStartupFilter, LoadTestRequestTrackingFilter>();
        builder.Services.AddHostedService<LoadTestHeartbeat>();
    }
}

// Counts requests entering and leaving the app. Three interlocked operations
// per request; no allocation, no logging.
public static class LoadTestRequestTracker
{
    private static long _inFlight;
    private static long _started;
    private static long _completed;
    private static long _lastCompletedTimestamp = Stopwatch.GetTimestamp();

    public static long InFlight => Interlocked.Read(ref _inFlight);

    public static long Started => Interlocked.Read(ref _started);

    public static long Completed => Interlocked.Read(ref _completed);

    public static long MsSinceLastCompleted => (long)Stopwatch.GetElapsedTime(Interlocked.Read(ref _lastCompletedTimestamp)).TotalMilliseconds;

    public static void Enter()
    {
        // The first request after an idle spell must not look stuck since the
        // last completion, which may be minutes old.
        if (Interlocked.Increment(ref _inFlight) == 1)
        {
            Interlocked.Exchange(ref _lastCompletedTimestamp, Stopwatch.GetTimestamp());
        }

        Interlocked.Increment(ref _started);
    }

    public static void Leave()
    {
        Interlocked.Exchange(ref _lastCompletedTimestamp, Stopwatch.GetTimestamp());
        Interlocked.Increment(ref _completed);
        Interlocked.Decrement(ref _inFlight);
    }
}

public sealed class LoadTestRequestTrackingFilter : IStartupFilter
{
    public Action<IApplicationBuilder> Configure(Action<IApplicationBuilder> next) => app =>
    {
        app.Use(async (HttpContext context, RequestDelegate nextMiddleware) =>
        {
            LoadTestRequestTracker.Enter();
            try
            {
                await nextMiddleware(context);
            }
            finally
            {
                LoadTestRequestTracker.Leave();
            }
        });
        next(app);
    };
}

public sealed class LoadTestHeartbeat : IHostedService, IDisposable
{
    private const int BeatMs = 1000;
    private const int SlowMs = 500;       // late / pool / share / local / sql
    private const int GcPauseMs = 200;
    private const int StuckMs = 2000;
    private const int SummaryEveryMs = 60000;

    // Requests in this database that are waiting on another session's lock, and
    // the longest such wait. SELECT 1 would come back instantly while every
    // content write queues on one lock row; this shows that queue. Reads a
    // system view only, so it takes no lock on Umbraco's tables itself.
    private const string SqlProbe =
        "SELECT COUNT(*), ISNULL(MAX(wait_time), 0) FROM sys.dm_exec_requests WHERE blocking_session_id <> 0";

    private readonly ILogger<LoadTestHeartbeat> _logger;
    private readonly string? _connectionString;
    private readonly string _sharePath;
    private readonly string _localPath;
    private readonly ManualResetEventSlim _stop = new(false);
    private readonly byte[] _payload = new byte[4096];
    private Thread? _thread;

    // Thread-pool probe state. _poolQueuedAt != 0 means a probe is still waiting.
    private long _poolQueuedAt;
    private long _poolLastDelayMs;

    public LoadTestHeartbeat(ILogger<LoadTestHeartbeat> logger, IConfiguration configuration, IHostEnvironment environment)
    {
        _logger = logger;
        _connectionString = configuration.GetConnectionString("umbracoDbDSN");
        string shareDir = Path.Combine(environment.ContentRootPath, "umbraco", "Data", "TEMP");
        _sharePath = Path.Combine(shareDir, "loadtest-heartbeat.tmp");
        _localPath = Path.Combine(Path.GetTempPath(), "loadtest-heartbeat.tmp");
        try
        {
            // Umbraco normally creates this folder; do not depend on it.
            Directory.CreateDirectory(shareDir);
        }
        catch (Exception)
        {
            // The share probe then reports share_failed on every beat.
        }
    }

    public Task StartAsync(CancellationToken cancellationToken)
    {
        _thread = new Thread(Run) { IsBackground = true, Name = "loadtest-heartbeat" };
        _thread.Start();
        ThreadPool.GetMinThreads(out int minWorkers, out int minIo);
        _logger.LogInformation(
            "LoadTestHeartbeat started: {Bitness}-bit process, server GC {ServerGc}, {Cores} cores, pool minimum {MinWorkers} worker / {MinIo} IO threads, share path {SharePath}, local path {LocalPath}",
            Environment.Is64BitProcess ? 64 : 32, System.Runtime.GCSettings.IsServerGC, Environment.ProcessorCount, minWorkers, minIo, _sharePath, _localPath);
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        _stop.Set();
        return Task.CompletedTask;
    }

    public void Dispose() => _stop.Dispose();

    private void Run()
    {
        var clock = Stopwatch.StartNew();
        TimeSpan lastGcPause = GC.GetTotalPauseDuration();
        int lastGen0 = GC.CollectionCount(0), lastGen1 = GC.CollectionCount(1), lastGen2 = GC.CollectionCount(2);
        long maxLate = 0, maxPool = 0, maxShare = 0, maxLocal = 0, maxSql = 0, maxGc = 0, maxInFlight = 0, maxStuck = 0, maxGap = 0, maxBlocked = 0, maxBlockedWait = 0;
        long lastStarted = LoadTestRequestTracker.Started, lastCompleted = LoadTestRequestTracker.Completed, minuteStarted = 0, minuteCompleted = 0;
        int beats = 0, slowBeats = 0, failedProbes = 0, sumGen0 = 0, sumGen1 = 0, sumGen2 = 0;
        long lastBeatAt = clock.ElapsedMilliseconds, summaryFrom = clock.ElapsedMilliseconds;

        while (true)
        {
            long sleepStart = clock.ElapsedMilliseconds;
            try
            {
                if (_stop.Wait(BeatMs))
                {
                    return;
                }
            }
            catch (ObjectDisposedException)
            {
                return;
            }

            long lateMs = clock.ElapsedMilliseconds - sleepStart - BeatMs;

            TimeSpan gcPauseNow = GC.GetTotalPauseDuration();
            long gcPauseMs = (long)(gcPauseNow - lastGcPause).TotalMilliseconds;
            lastGcPause = gcPauseNow;
            int gen0 = GC.CollectionCount(0), gen1 = GC.CollectionCount(1), gen2 = GC.CollectionCount(2);
            int dGen0 = gen0 - lastGen0, dGen1 = gen1 - lastGen1, dGen2 = gen2 - lastGen2;
            lastGen0 = gen0; lastGen1 = gen1; lastGen2 = gen2;

            // What the app saw is read BEFORE the probes: they run on this
            // thread and one that hangs would otherwise delay the reading.
            long inFlight = LoadTestRequestTracker.InFlight;
            long stuckMs = inFlight > 0 ? LoadTestRequestTracker.MsSinceLastCompleted : 0;
            long started = LoadTestRequestTracker.Started, completed = LoadTestRequestTracker.Completed;
            long dStarted = started - lastStarted, dCompleted = completed - lastCompleted;
            lastStarted = started; lastCompleted = completed;
            int poolThreads = ThreadPool.ThreadCount;
            long poolPending = ThreadPool.PendingWorkItemCount;

            long poolMs = ProbeThreadPool(clock);
            long shareMs = TimeWrite(_sharePath, out bool shareFailed);
            long localMs = TimeWrite(_localPath, out bool localFailed);
            long sqlMs = TimeSql(out bool sqlFailed, out long sqlBlocked, out long sqlBlockedWaitMs);

            // Time since the previous beat was finished. About one second
            // normally; a probe that hung shows here as the length of the hang.
            long now = clock.ElapsedMilliseconds;
            long gapMs = now - lastBeatAt;
            lastBeatAt = now;

            maxInFlight = Math.Max(maxInFlight, inFlight); maxStuck = Math.Max(maxStuck, stuckMs);
            minuteStarted += dStarted; minuteCompleted += dCompleted;
            maxLate = Math.Max(maxLate, lateMs); maxPool = Math.Max(maxPool, poolMs);
            maxShare = Math.Max(maxShare, shareMs); maxLocal = Math.Max(maxLocal, localMs);
            maxSql = Math.Max(maxSql, sqlMs); maxGc = Math.Max(maxGc, gcPauseMs);
            maxGap = Math.Max(maxGap, gapMs);
            maxBlocked = Math.Max(maxBlocked, sqlBlocked); maxBlockedWait = Math.Max(maxBlockedWait, sqlBlockedWaitMs);
            sumGen0 += dGen0; sumGen1 += dGen1; sumGen2 += dGen2;
            beats++;
            if (shareFailed) { failedProbes++; }
            if (localFailed) { failedProbes++; }
            if (sqlFailed) { failedProbes++; }

            bool slow = lateMs >= SlowMs || poolMs >= SlowMs || shareMs >= SlowMs || localMs >= SlowMs || sqlMs >= SlowMs
                || gcPauseMs >= GcPauseMs || stuckMs >= StuckMs || shareFailed || localFailed || sqlFailed || sqlBlockedWaitMs >= StuckMs;
            if (slow) { slowBeats++; }

            // Every beat is logged, a slow one as a Warning. The seconds in
            // which nothing crossed a threshold matter too: "started=0 while
            // the load test was sending" is only visible if they are there.
            _logger.Log(
                slow ? LogLevel.Warning : LogLevel.Information,
                "LoadTestHeartbeat beat: late_ms={LateMs} gap_ms={GapMs} gc_pause_ms={GcPauseMs} gen0={Gen0} gen1={Gen1} gen2={Gen2} pool_ms={PoolMs} pool_threads={PoolThreads} pool_pending={PoolPending} share_ms={ShareMs} share_failed={ShareFailed} local_ms={LocalMs} local_failed={LocalFailed} sql_ms={SqlMs} sql_failed={SqlFailed} sql_blocked={SqlBlocked} sql_blocked_wait_ms={SqlBlockedWaitMs} in_flight={InFlight} stuck_ms={StuckMs} started={Started} completed={Completed} heap_mb={HeapMb}",
                lateMs, gapMs, gcPauseMs, dGen0, dGen1, dGen2, poolMs, poolThreads, poolPending, shareMs, shareFailed, localMs, localFailed, sqlMs, sqlFailed, sqlBlocked, sqlBlockedWaitMs, inFlight, stuckMs, dStarted, dCompleted, GC.GetTotalMemory(false) / (1024 * 1024));

            // By the clock, not by beat count: beats stop while a probe hangs.
            if (now - summaryFrom >= SummaryEveryMs)
            {
                _logger.LogInformation(
                    "LoadTestHeartbeat minute: seconds={Seconds} beats={Beats} slow_beats={SlowBeats} failed_probes={FailedProbes} max_late_ms={MaxLateMs} max_gap_ms={MaxGapMs} max_gc_pause_ms={MaxGcPauseMs} gen0={Gen0} gen1={Gen1} gen2={Gen2} max_pool_ms={MaxPoolMs} pool_threads={PoolThreads} max_share_ms={MaxShareMs} max_local_ms={MaxLocalMs} max_sql_ms={MaxSqlMs} max_sql_blocked={MaxSqlBlocked} max_sql_blocked_wait_ms={MaxSqlBlockedWaitMs} max_in_flight={MaxInFlight} max_stuck_ms={MaxStuckMs} started={Started} completed={Completed} heap_mb={HeapMb}",
                    (now - summaryFrom) / 1000, beats, slowBeats, failedProbes, maxLate, maxGap, maxGc, sumGen0, sumGen1, sumGen2, maxPool, ThreadPool.ThreadCount, maxShare, maxLocal, maxSql, maxBlocked, maxBlockedWait, maxInFlight, maxStuck, minuteStarted, minuteCompleted, GC.GetTotalMemory(false) / (1024 * 1024));
                maxLate = maxPool = maxShare = maxLocal = maxSql = maxGc = maxInFlight = maxStuck = maxGap = maxBlocked = maxBlockedWait = minuteStarted = minuteCompleted = 0;
                beats = slowBeats = failedProbes = sumGen0 = sumGen1 = sumGen2 = 0;
                summaryFrom = now;
            }
        }
    }

    // Returns how long the previous probe waited for a pool thread, or how long
    // it has been waiting so far if it still has not started. Queues the next
    // probe only when the previous one has run, so a starved pool is not fed.
    private long ProbeThreadPool(Stopwatch clock)
    {
        long queuedAt = Interlocked.Read(ref _poolQueuedAt);
        if (queuedAt != 0)
        {
            return clock.ElapsedMilliseconds - queuedAt;
        }

        long delay = Interlocked.Read(ref _poolLastDelayMs);
        long now = Math.Max(1, clock.ElapsedMilliseconds);
        Interlocked.Exchange(ref _poolQueuedAt, now);
        ThreadPool.UnsafeQueueUserWorkItem(
            _ =>
            {
                Interlocked.Exchange(ref _poolLastDelayMs, clock.ElapsedMilliseconds - now);
                Interlocked.Exchange(ref _poolQueuedAt, 0);
            },
            null);
        return delay;
    }

    // Milliseconds for a 4 KB write flushed to the device. A write that throws
    // still reports how long it took to fail (a share that times out after 20 s
    // must not read as a fast probe) and sets failed.
    private long TimeWrite(string path, out bool failed)
    {
        failed = false;
        long start = Stopwatch.GetTimestamp();
        try
        {
            using var stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read, 4096, FileOptions.WriteThrough);
            stream.Write(_payload, 0, _payload.Length);
            stream.Flush(true);
        }
        catch (Exception)
        {
            failed = true;
        }

        return (long)Stopwatch.GetElapsedTime(start).TotalMilliseconds;
    }

    // Milliseconds to open a pooled connection (the site's own pool, so an
    // exhausted pool shows as a long sql_ms) and run SqlProbe. blocked is the
    // number of requests waiting on another session's lock, blockedWaitMs the
    // longest such wait. Failing, or having no connection string, sets failed
    // and still reports the time it took.
    private long TimeSql(out bool failed, out long blocked, out long blockedWaitMs)
    {
        failed = false;
        blocked = 0;
        blockedWaitMs = 0;
        if (string.IsNullOrEmpty(_connectionString))
        {
            failed = true;
            return 0;
        }

        long start = Stopwatch.GetTimestamp();
        try
        {
            using var connection = new SqlConnection(_connectionString);
            connection.Open();
            using SqlCommand command = connection.CreateCommand();
            command.CommandText = SqlProbe;
            command.CommandTimeout = 60;
            using SqlDataReader reader = command.ExecuteReader();
            if (reader.Read())
            {
                blocked = Convert.ToInt64(reader.GetValue(0));
                blockedWaitMs = Convert.ToInt64(reader.GetValue(1));
            }
        }
        catch (Exception)
        {
            failed = true;
        }

        return (long)Stopwatch.GetElapsedTime(start).TotalMilliseconds;
    }
}
