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
//   cpu_ms     CPU time the whole process used since the previous beat, per
//              second. One core gives 1000: near cores x 1000 means the
//              process was CPU-bound, which Azure Monitor's per-minute figure
//              averages away. cpu_span_ms is the time the reading covers:
//              about 1000, more when a probe of the previous beat hung.
//   top_threads  on a slow or CPU-heavy beat, the three OS threads that used
//              most CPU over that same span (id:ms, not scaled). One thread
//              close to the span is a single background job; many threads
//              sharing it is request work.
//   gc2 / gc_reason  generation-2 collections started since the previous beat
//              and the runtime's reason code for the last collection.
//   contention_n / contention_max_ms  managed lock waits (Monitor) that ended
//              since the previous beat, and the longest one.
//   starvation  times the runtime added a pool thread because it judged the
//              pool starved. Non-zero is the runtime itself saying requests
//              are blocking its threads.
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
using System.Collections.Generic;
using System.Diagnostics;
using System.Diagnostics.Tracing;
using System.IO;
using System.Linq;
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

// Counts a few of the runtime's own events between beats: generation-2
// collections, managed lock contention, and the thread pool growing because it
// judged itself starved. Callbacks only touch interlocked counters - logging
// from inside an EventListener callback can re-enter the event pipeline.
public sealed class LoadTestRuntimeEvents : EventListener
{
    private const EventKeywords GcKeyword = (EventKeywords)0x1;
    private const EventKeywords ContentionKeyword = (EventKeywords)0x4000;
    private const EventKeywords ThreadingKeyword = (EventKeywords)0x10000;
    private const uint StarvationReason = 6;

    private long _gen2Starts;
    private long _lastGcReason = -1;
    private long _contentions;
    private long _contentionMaxNs;
    private long _starvationAdjustments;

    // Each call returns what happened since the previous call.
    public void Drain(out long gen2Starts, out long lastGcReason, out long contentions, out long contentionMaxMs, out long starvationAdjustments)
    {
        gen2Starts = Interlocked.Exchange(ref _gen2Starts, 0);
        lastGcReason = Interlocked.Exchange(ref _lastGcReason, -1);
        contentions = Interlocked.Exchange(ref _contentions, 0);
        contentionMaxMs = Interlocked.Exchange(ref _contentionMaxNs, 0) / 1_000_000;
        starvationAdjustments = Interlocked.Exchange(ref _starvationAdjustments, 0);
    }

    // Called from the base constructor, before this class's own fields are
    // assigned: it must not touch instance state.
    protected override void OnEventSourceCreated(EventSource eventSource)
    {
        if (eventSource.Name == "Microsoft-Windows-DotNETRuntime")
        {
            EnableEvents(eventSource, EventLevel.Informational, GcKeyword | ContentionKeyword | ThreadingKeyword);
        }
    }

    protected override void OnEventWritten(EventWrittenEventArgs eventData)
    {
        try
        {
            string? name = eventData.EventName;
            if (name is null)
            {
                return;
            }

            if (name.StartsWith("GCStart", StringComparison.Ordinal))
            {
                if (Payload(eventData, "Depth") == 2)
                {
                    Interlocked.Increment(ref _gen2Starts);
                }

                Interlocked.Exchange(ref _lastGcReason, Payload(eventData, "Reason"));
            }
            else if (name.StartsWith("ContentionStop", StringComparison.Ordinal))
            {
                Interlocked.Increment(ref _contentions);
                long ns = Payload(eventData, "DurationNs");
                long seen;
                while (ns > (seen = Interlocked.Read(ref _contentionMaxNs)) &&
                       Interlocked.CompareExchange(ref _contentionMaxNs, ns, seen) != seen)
                {
                }
            }
            else if (name.StartsWith("ThreadPoolWorkerThreadAdjustmentAdjustment", StringComparison.Ordinal))
            {
                if (Payload(eventData, "Reason") == StarvationReason)
                {
                    Interlocked.Increment(ref _starvationAdjustments);
                }
            }
        }
        catch (Exception)
        {
            // A diagnostic must never take the site down.
        }
    }

    private static long Payload(EventWrittenEventArgs eventData, string field)
    {
        int index = eventData.PayloadNames?.IndexOf(field) ?? -1;
        if (index < 0 || eventData.Payload is null || index >= eventData.Payload.Count || eventData.Payload[index] is null)
        {
            return -1;
        }

        try
        {
            return Convert.ToInt64(eventData.Payload[index], System.Globalization.CultureInfo.InvariantCulture);
        }
        catch (Exception)
        {
            return -1;
        }
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
    private const int HeavyCpuMs = 700;   // per beat; one core is about 1000

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
    private LoadTestRuntimeEvents? _runtimeEvents;

    // Per-thread CPU at the previous beat, to name the threads that used most
    // since. Null once reading it has failed (the App Service sandbox may not
    // allow it): the field is then logged as "n/a".
    private Dictionary<int, double>? _threadCpu = new();

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
        try
        {
            _runtimeEvents = new LoadTestRuntimeEvents();
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "LoadTestHeartbeat could not listen to runtime events; gc2, contention and starvation will read 0");
        }
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

    public void Dispose()
    {
        _runtimeEvents?.Dispose();
        _stop.Dispose();
    }

    // The three OS threads that used most CPU since the previous call, as
    // "id:ms,id:ms,id:ms" ("-" when there is nothing to name). Always called, so
// the next slow beat has a baseline. The figures cover the time since the
// previous call - see cpu_span_ms on the beat line.
    private string TopThreads()
    {
        Dictionary<int, double>? previous = _threadCpu;
        if (previous is null)
        {
            return "n/a";
        }

        try
        {
            var current = new Dictionary<int, double>();
            using Process process = Process.GetCurrentProcess();
            foreach (ProcessThread thread in process.Threads)
            {
                try
                {
                    current[thread.Id] = thread.TotalProcessorTime.TotalMilliseconds;
                }
                catch (Exception)
                {
                    // The thread ended while it was being read.
                }
                finally
                {
                    thread.Dispose();
                }
            }

            _threadCpu = current;
            if (previous.Count == 0)
            {
                // First call: no earlier reading to subtract, and lifetime
                // totals would read as one second's work.
                return "-";
            }

            string top = string.Join(',', current
                .Select(kv => (Id: kv.Key, Ms: (long)(kv.Value - (previous.TryGetValue(kv.Key, out double before) ? before : 0))))
                .Where(t => t.Ms > 0)
                .OrderByDescending(t => t.Ms)
                .Take(3)
                .Select(t => $"{t.Id}:{t.Ms}"));
            return top.Length > 0 ? top : "-";
        }
        catch (Exception)
        {
            _threadCpu = null;
            return "n/a";
        }
    }

    private void Run()
    {
        var clock = Stopwatch.StartNew();
        TimeSpan lastGcPause = GC.GetTotalPauseDuration();
        int lastGen0 = GC.CollectionCount(0), lastGen1 = GC.CollectionCount(1), lastGen2 = GC.CollectionCount(2);
        long maxLate = 0, maxPool = 0, maxShare = 0, maxLocal = 0, maxSql = 0, maxGc = 0, maxInFlight = 0, maxStuck = 0, maxGap = 0, maxBlocked = 0, maxBlockedWait = 0;
        long lastStarted = LoadTestRequestTracker.Started, lastCompleted = LoadTestRequestTracker.Completed, minuteStarted = 0, minuteCompleted = 0;
        int beats = 0, slowBeats = 0, failedProbes = 0, sumGen0 = 0, sumGen1 = 0, sumGen2 = 0;
        long lastBeatAt = clock.ElapsedMilliseconds, summaryFrom = clock.ElapsedMilliseconds;
        TimeSpan lastCpu = Environment.CpuUsage.TotalTime;
        long lastCpuAt = clock.ElapsedMilliseconds;
        TopThreads();   // baseline for the first beat
        long maxCpu = 0, maxContention = 0, sumStarvation = 0, sumContentions = 0;

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

            // Also read before the probes, for the same reason.
            TimeSpan cpuNow = Environment.CpuUsage.TotalTime;
            // The reading covers the time since the previous reading, which is
            // longer than a second when a probe of the previous beat hung.
            // Scaled to one second, so "near cores x 1000" keeps its meaning;
            // cpu_span_ms says how long the reading actually covers.
            long cpuAt = clock.ElapsedMilliseconds;
            long cpuSpanMs = Math.Max(1, cpuAt - lastCpuAt);
            long cpuMs = (long)((cpuNow - lastCpu).TotalMilliseconds * 1000 / cpuSpanMs);
            lastCpu = cpuNow;
            lastCpuAt = cpuAt;
            long gen2Starts = 0, gcReason = -1, contentions = 0, contentionMaxMs = 0, starvation = 0;
            _runtimeEvents?.Drain(out gen2Starts, out gcReason, out contentions, out contentionMaxMs, out starvation);
            string topThreads = TopThreads();

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
            maxCpu = Math.Max(maxCpu, cpuMs); maxContention = Math.Max(maxContention, contentionMaxMs);
            sumStarvation += starvation; sumContentions += contentions;
            // Named only where it matters: a slow beat, or a second in which
            // the process used most of a core.
            if (!slow && cpuMs < HeavyCpuMs) { topThreads = "-"; }

            // Every beat is logged, a slow one as a Warning. The seconds in
            // which nothing crossed a threshold matter too: "started=0 while
            // the load test was sending" is only visible if they are there.
            _logger.Log(
                slow ? LogLevel.Warning : LogLevel.Information,
                "LoadTestHeartbeat beat: late_ms={LateMs} gap_ms={GapMs} cpu_ms={CpuMs} cpu_span_ms={CpuSpanMs} top_threads={TopThreads} gc_pause_ms={GcPauseMs} gen0={Gen0} gen1={Gen1} gen2={Gen2} gc2={Gc2Starts} gc_reason={GcReason} contention_n={Contentions} contention_max_ms={ContentionMaxMs} starvation={Starvation} pool_ms={PoolMs} pool_threads={PoolThreads} pool_pending={PoolPending} share_ms={ShareMs} share_failed={ShareFailed} local_ms={LocalMs} local_failed={LocalFailed} sql_ms={SqlMs} sql_failed={SqlFailed} sql_blocked={SqlBlocked} sql_blocked_wait_ms={SqlBlockedWaitMs} in_flight={InFlight} stuck_ms={StuckMs} started={Started} completed={Completed} heap_mb={HeapMb}",
                lateMs, gapMs, cpuMs, cpuSpanMs, topThreads, gcPauseMs, dGen0, dGen1, dGen2, gen2Starts, gcReason, contentions, contentionMaxMs, starvation, poolMs, poolThreads, poolPending, shareMs, shareFailed, localMs, localFailed, sqlMs, sqlFailed, sqlBlocked, sqlBlockedWaitMs, inFlight, stuckMs, dStarted, dCompleted, GC.GetTotalMemory(false) / (1024 * 1024));

            // By the clock, not by beat count: beats stop while a probe hangs.
            if (now - summaryFrom >= SummaryEveryMs)
            {
                _logger.LogInformation(
                    "LoadTestHeartbeat minute: seconds={Seconds} beats={Beats} slow_beats={SlowBeats} failed_probes={FailedProbes} max_cpu_ms={MaxCpuMs} contentions={Contentions} max_contention_ms={MaxContentionMs} starvation={Starvation} max_late_ms={MaxLateMs} max_gap_ms={MaxGapMs} max_gc_pause_ms={MaxGcPauseMs} gen0={Gen0} gen1={Gen1} gen2={Gen2} max_pool_ms={MaxPoolMs} pool_threads={PoolThreads} max_share_ms={MaxShareMs} max_local_ms={MaxLocalMs} max_sql_ms={MaxSqlMs} max_sql_blocked={MaxSqlBlocked} max_sql_blocked_wait_ms={MaxSqlBlockedWaitMs} max_in_flight={MaxInFlight} max_stuck_ms={MaxStuckMs} started={Started} completed={Completed} heap_mb={HeapMb}",
                    (now - summaryFrom) / 1000, beats, slowBeats, failedProbes, maxCpu, sumContentions, maxContention, sumStarvation, maxLate, maxGap, maxGc, sumGen0, sumGen1, sumGen2, maxPool, ThreadPool.ThreadCount, maxShare, maxLocal, maxSql, maxBlocked, maxBlockedWait, maxInFlight, maxStuck, minuteStarted, minuteCompleted, GC.GetTotalMemory(false) / (1024 * 1024));
                maxLate = maxPool = maxShare = maxLocal = maxSql = maxGc = maxInFlight = maxStuck = maxGap = maxBlocked = maxBlockedWait = minuteStarted = minuteCompleted = 0;
                beats = slowBeats = failedProbes = sumGen0 = sumGen1 = sumGen2 = 0;
                maxCpu = maxContention = sumStarvation = sumContentions = 0;
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
