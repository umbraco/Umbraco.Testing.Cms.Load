// Diagnostic overlay for the Heartbeat scenario. Not part of the measured product.
//
// Frontend runs show whole-site pauses: for 8-18 s every request hangs, then all
// of them complete in the same second, while Umbraco logs nothing and CPU, SQL
// DTU and the request queue look idle (builds 305559, 305676, 305703, 305770,
// 305781). The per-minute Azure Monitor metrics cannot tell a frozen process
// from a blocked thread pool from a hung file share from a slow database.
//
// This hosted service beats once a second on its OWN thread (not a thread-pool
// thread, so a starved pool cannot delay it) and times four things:
//
//   late_ms    how late the beat woke up. Large with gc_pause_ms large: the
//              garbage collector froze the process. Large with gc_pause_ms
//              small: the process was frozen or starved from outside.
//   pool_ms    how long a queued thread-pool work item waited to start. Large
//              while late_ms is small: the thread pool is starved (requests
//              are blocking its threads), the process itself is fine.
//   share_ms   a small write to the site folder, which on App Service is a
//              remote file share. local_ms is the same write to local temp.
//   sql_ms     open a pooled connection and run SELECT 1.
//
// A small middleware at the front of the pipeline also counts requests, so a
// beat knows what the app itself saw:
//
//   in_flight  requests inside the app right now; started / completed are the
//              counts since the previous beat.
//   stuck_ms   with requests in flight, how long since any request completed.
//              Large with in_flight large and the probes above all normal:
//              requests are waiting inside the app on something asynchronous
//              (a lock, a cache rebuild) that blocks no thread.
//              in_flight 0 and started 0 during a pause: the requests never
//              reached the app - the stall is in front of it (App Service
//              front end, network, or the load generator).
//
// A beat is logged as a Warning when any of these crosses its threshold, and a
// one-line summary with each maximum is logged every minute, so a clean run
// shows the baseline. Read the lines for the seconds of a pause the publish
// step reports ("whole-site pause(s) ... at HH:mm:ss UTC") in
// umbraco/Logs/UmbracoTraceLog.*.json.
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
    private const int SummaryEveryBeats = 60;

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
    }

    public Task StartAsync(CancellationToken cancellationToken)
    {
        _thread = new Thread(Run) { IsBackground = true, Name = "loadtest-heartbeat" };
        _thread.Start();
        _logger.LogInformation(
            "LoadTestHeartbeat started: {Bitness}-bit process, server GC {ServerGc}, {Cores} cores, share path {SharePath}, local path {LocalPath}",
            Environment.Is64BitProcess ? 64 : 32, System.Runtime.GCSettings.IsServerGC, Environment.ProcessorCount, _sharePath, _localPath);
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
        long maxLate = 0, maxPool = 0, maxShare = 0, maxLocal = 0, maxSql = 0, maxGc = 0, maxInFlight = 0, maxStuck = 0;
        long lastStarted = LoadTestRequestTracker.Started, lastCompleted = LoadTestRequestTracker.Completed, minuteCompleted = 0;
        int beats = 0, sumGen0 = 0, sumGen1 = 0, sumGen2 = 0;

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

            long poolMs = ProbeThreadPool(clock);
            long shareMs = TimeWrite(_sharePath);
            long localMs = TimeWrite(_localPath);
            long sqlMs = TimeSql();

            long inFlight = LoadTestRequestTracker.InFlight;
            long stuckMs = inFlight > 0 ? LoadTestRequestTracker.MsSinceLastCompleted : 0;
            long started = LoadTestRequestTracker.Started, completed = LoadTestRequestTracker.Completed;
            long dStarted = started - lastStarted, dCompleted = completed - lastCompleted;
            lastStarted = started; lastCompleted = completed;
            maxInFlight = Math.Max(maxInFlight, inFlight); maxStuck = Math.Max(maxStuck, stuckMs);
            minuteCompleted += dCompleted;

            maxLate = Math.Max(maxLate, lateMs); maxPool = Math.Max(maxPool, poolMs);
            maxShare = Math.Max(maxShare, shareMs); maxLocal = Math.Max(maxLocal, localMs);
            maxSql = Math.Max(maxSql, sqlMs); maxGc = Math.Max(maxGc, gcPauseMs);
            sumGen0 += dGen0; sumGen1 += dGen1; sumGen2 += dGen2;
            beats++;

            if (lateMs >= SlowMs || poolMs >= SlowMs || shareMs >= SlowMs || localMs >= SlowMs || sqlMs >= SlowMs || gcPauseMs >= GcPauseMs || stuckMs >= StuckMs)
            {
                _logger.LogWarning(
                    "LoadTestHeartbeat slow beat: late_ms={LateMs} gc_pause_ms={GcPauseMs} gen0={Gen0} gen1={Gen1} gen2={Gen2} pool_ms={PoolMs} pool_threads={PoolThreads} pool_pending={PoolPending} share_ms={ShareMs} local_ms={LocalMs} sql_ms={SqlMs} in_flight={InFlight} stuck_ms={StuckMs} started={Started} completed={Completed} heap_mb={HeapMb}",
                    lateMs, gcPauseMs, dGen0, dGen1, dGen2, poolMs, ThreadPool.ThreadCount, ThreadPool.PendingWorkItemCount, shareMs, localMs, sqlMs, inFlight, stuckMs, dStarted, dCompleted, GC.GetTotalMemory(false) / (1024 * 1024));
            }

            if (beats >= SummaryEveryBeats)
            {
                _logger.LogInformation(
                    "LoadTestHeartbeat minute: beats={Beats} max_late_ms={MaxLateMs} max_gc_pause_ms={MaxGcPauseMs} gen0={Gen0} gen1={Gen1} gen2={Gen2} max_pool_ms={MaxPoolMs} pool_threads={PoolThreads} max_share_ms={MaxShareMs} max_local_ms={MaxLocalMs} max_sql_ms={MaxSqlMs} max_in_flight={MaxInFlight} max_stuck_ms={MaxStuckMs} completed={Completed} heap_mb={HeapMb}",
                    beats, maxLate, maxGc, sumGen0, sumGen1, sumGen2, maxPool, ThreadPool.ThreadCount, maxShare, maxLocal, maxSql, maxInFlight, maxStuck, minuteCompleted, GC.GetTotalMemory(false) / (1024 * 1024));
                maxLate = maxPool = maxShare = maxLocal = maxSql = maxGc = maxInFlight = maxStuck = minuteCompleted = 0;
                beats = sumGen0 = sumGen1 = sumGen2 = 0;
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

    // Milliseconds for a 4 KB write flushed to the device, or -1 if it failed.
    private long TimeWrite(string path)
    {
        long start = Stopwatch.GetTimestamp();
        try
        {
            using var stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read, 4096, FileOptions.WriteThrough);
            stream.Write(_payload, 0, _payload.Length);
            stream.Flush(true);
        }
        catch (Exception)
        {
            return -1;
        }

        return (long)Stopwatch.GetElapsedTime(start).TotalMilliseconds;
    }

    // Milliseconds to open a pooled connection and run SELECT 1, or -1 if it
    // failed or no connection string is configured.
    private long TimeSql()
    {
        if (string.IsNullOrEmpty(_connectionString))
        {
            return -1;
        }

        long start = Stopwatch.GetTimestamp();
        try
        {
            using var connection = new SqlConnection(_connectionString);
            connection.Open();
            using SqlCommand command = connection.CreateCommand();
            command.CommandText = "SELECT 1";
            command.CommandTimeout = 60;
            command.ExecuteScalar();
        }
        catch (Exception)
        {
            return -1;
        }

        return (long)Stopwatch.GetElapsedTime(start).TotalMilliseconds;
    }
}
