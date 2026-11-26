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
//              most CPU over that same span (id:ms:name, not scaled). One
//              thread close to the span is a single background job; many
//              threads sharing it is request work. The name is the one the
//              thread was given (".NET_TP_Worker" is a thread-pool thread,
//              ".NET_Server_GC" the collector, a library's own name its own
//              thread); "?" when it has none or it could not be read.
//   jit_n      methods compiled since the previous beat. A burst long after
//              start-up means code is running for the first time: something
//              was compiled or loaded at run time, or a job ran its first lap.
//   Cost lines, once a minute. These are for comparing versions, not for
//   diagnosing pauses: what an operation costs barely varies between runs,
//   where its response time does.
//     "LoadTestHeartbeat cost: class=... n=... ms=... sql_n=... sql_ms=...
//      commit_ms=..." - one line per kind of request (Home, Section, Category,
//      Page, Detail, Media, FormPost, SeederApi, Other) with what all requests
//      of that kind used in the minute: divide by n for the cost of one. A
//      page or media request that ran any SQL is counted under its kind plus
//      "Loaded" (PageLoaded, DetailLoaded, ...): its content was not in
//      memory and had to be loaded from the database first.
//     "LoadTestHeartbeat cost total: requests=... cpu_ms=... alloc_mb=...
//      gen0=... gen1=... gen2=..." - what the whole process used in the same
//      minute, so CPU and memory allocated per request can be worked out.
//   asm_n      assemblies loaded since the previous beat; their names follow
//              on a "LoadTestHeartbeat assemblies loaded" line. An assembly
//              arriving mid-run is run-time compilation (models, views).
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
//   oldest_ms  age of the oldest request still inside the app. stuck_ms stays
//              small when only some requests hang and the rest keep
//              completing; this does not.
//   slow_n / max_req_ms  requests that finished since the previous beat having
//              spent 100 ms or more inside the app, and the longest.
//
// Each of those slow requests also gets its own line ("LoadTestHeartbeat slow
// request"), written by the beat thread within about a second of the request
// ending - ended_utc is when it actually ended:
//
//   ms         time inside the app, from the first middleware to the last.
//              Compare with the load test's own time for the same request
//              (same path, same end second): a request the client waited 2 s
//              for that shows 6 ms here, or no line at all, spent that time
//              outside the app - in front of it or on the way back.
//   sql_n / sql_ms  SQL commands the request ran and their total time, up to
//              the point each command returns (not reading its rows).
//              commit_ms is transaction commits, open_ms opening connections
//              (long when the connection pool is empty).
//              ms far above sql_ms + commit_ms + open_ms: the request waited
//              or computed inside the app. Close to it: it waited on the
//              database.
//   in_flight_at_start  other requests inside the app when this one arrived.
//
// The SQL figures come from Microsoft.Data.SqlClient's diagnostic events,
// which are only produced while something listens: this scenario's SQL calls
// are a little more expensive than the Default scenario's.
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
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Diagnostics.Tracing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
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
        // Experiment switch, set in this scenario's appsettings.json. .NET starts
        // with one worker thread per core and adds more only slowly, so a few
        // requests that hold a thread (the contact form's synchronous save) can
        // leave page requests waiting for one. A value above 0 raises that
        // minimum; 0 or absent leaves the runtime's default, which is what a
        // normal site runs with. The "started" line logs the minimum in force.
        if (int.TryParse(builder.Config["LoadTest:MinWorkerThreads"], out int wantedWorkers) && wantedWorkers > 0)
        {
            ThreadPool.GetMinThreads(out int currentWorkers, out int currentIo);
            ThreadPool.SetMinThreads(Math.Max(currentWorkers, wantedWorkers), currentIo);
        }

        builder.Services.AddTransient<IStartupFilter, LoadTestRequestTrackingFilter>();
        builder.Services.AddHostedService<LoadTestHeartbeat>();
    }
}

// What one request did, filled in while it runs. One small object per request.
public sealed class LoadTestRequestStats
{
    public long StartTimestamp;
    public long InFlightAtStart;
    public long SqlCommands;
    public long SqlTicks;
    public long CommitTicks;
    public long OpenTicks;

    // Start of the SQL operation in progress, 0 when none. A request runs its
    // commands one after another, so one slot per kind is enough.
    public long CommandStartedAt;
    public long CommitStartedAt;
    public long OpenStartedAt;
}

// A finished slow request, waiting for the beat thread to log it.
public sealed record LoadTestSlowRequest(
    DateTime EndedUtc, long Ms, string Method, string Path, int Status, long InFlightAtStart,
    long SqlCommands, long SqlMs, long CommitMs, long OpenMs);

// Counts and times requests entering and leaving the app. Nothing is logged
// from the request's own thread: slow requests are queued for the beat thread.
public static class LoadTestRequestTracker
{
    public const int SlowRequestMs = 100;
    private const int MaxQueuedSlowRequests = 5000;

    private static readonly AsyncLocal<LoadTestRequestStats?> CurrentStats = new();
    private static readonly ConcurrentDictionary<LoadTestRequestStats, byte> Running = new();
    private static readonly ConcurrentQueue<LoadTestSlowRequest> SlowQueue = new();

    private static long _inFlight;
    private static long _started;
    private static long _completed;
    private static long _lastCompletedTimestamp = Stopwatch.GetTimestamp();
    private static long _slowCount;
    private static long _slowDropped;
    private static long _maxRequestMs;

    // What each kind of request used since the last DrainCost:
    // [0] requests, [1] elapsed ticks, [2] SQL commands, [3] SQL ticks, [4] commit ticks.
    private static readonly ConcurrentDictionary<string, long[]> Cost = new();

    public static long InFlight => Interlocked.Read(ref _inFlight);

    public static long Started => Interlocked.Read(ref _started);

    public static long Completed => Interlocked.Read(ref _completed);

    public static long MsSinceLastCompleted => (long)Stopwatch.GetElapsedTime(Interlocked.Read(ref _lastCompletedTimestamp)).TotalMilliseconds;

    // The request the calling code is running in, or null outside a request
    // (background jobs, the heartbeat's own SQL probe).
    public static LoadTestRequestStats? Current => CurrentStats.Value;

    // Age of the oldest request still inside the app, 0 when there is none.
    public static long OldestMs
    {
        get
        {
            long oldest = 0;
            foreach (LoadTestRequestStats stats in Running.Keys)
            {
                long started = stats.StartTimestamp;
                if (oldest == 0 || started < oldest)
                {
                    oldest = started;
                }
            }

            return oldest == 0 ? 0 : (long)Stopwatch.GetElapsedTime(oldest).TotalMilliseconds;
        }
    }

    public static LoadTestRequestStats Enter()
    {
        // The first request after an idle spell must not look stuck since the
        // last completion, which may be minutes old.
        long inFlight = Interlocked.Increment(ref _inFlight);
        if (inFlight == 1)
        {
            Interlocked.Exchange(ref _lastCompletedTimestamp, Stopwatch.GetTimestamp());
        }

        Interlocked.Increment(ref _started);
        var stats = new LoadTestRequestStats { StartTimestamp = Stopwatch.GetTimestamp(), InFlightAtStart = inFlight - 1 };
        Running[stats] = 0;
        CurrentStats.Value = stats;
        return stats;
    }

    public static void Leave(LoadTestRequestStats stats, HttpContext context)
    {
        long now = Stopwatch.GetTimestamp();
        Interlocked.Exchange(ref _lastCompletedTimestamp, now);
        Interlocked.Increment(ref _completed);
        Interlocked.Decrement(ref _inFlight);
        Running.TryRemove(stats, out _);

        long ms = (long)Stopwatch.GetElapsedTime(stats.StartTimestamp, now).TotalMilliseconds;
        long seen;
        while (ms > (seen = Interlocked.Read(ref _maxRequestMs)) &&
               Interlocked.CompareExchange(ref _maxRequestMs, ms, seen) != seen)
        {
        }

        try
        {
            // A page or media request that needed SQL had to load its content
            // from the database; one that needed none was served from memory.
            // The two cost very different amounts, so they are counted apart.
            long sqlCommands = Interlocked.Read(ref stats.SqlCommands);
            string kind = Classify(context.Request.Method, context.Request.Path.Value);
            if (sqlCommands > 0 && kind is "Home" or "Section" or "Category" or "Page" or "Detail" or "Media")
            {
                kind += "Loaded";
            }

            long[] cost = Cost.GetOrAdd(kind, _ => new long[5]);
            Interlocked.Increment(ref cost[0]);
            Interlocked.Add(ref cost[1], now - stats.StartTimestamp);
            Interlocked.Add(ref cost[2], sqlCommands);
            Interlocked.Add(ref cost[3], Interlocked.Read(ref stats.SqlTicks));
            Interlocked.Add(ref cost[4], Interlocked.Read(ref stats.CommitTicks));
        }
        catch (Exception)
        {
            // A diagnostic must never fail a request.
        }

        if (ms < SlowRequestMs)
        {
            return;
        }

        Interlocked.Increment(ref _slowCount);
        if (SlowQueue.Count >= MaxQueuedSlowRequests)
        {
            Interlocked.Increment(ref _slowDropped);
            return;
        }

        try
        {
            SlowQueue.Enqueue(new LoadTestSlowRequest(
                DateTime.UtcNow, ms, context.Request.Method, context.Request.Path.Value ?? string.Empty, context.Response.StatusCode,
                stats.InFlightAtStart, Interlocked.Read(ref stats.SqlCommands), ToMs(Interlocked.Read(ref stats.SqlTicks)),
                ToMs(Interlocked.Read(ref stats.CommitTicks)), ToMs(Interlocked.Read(ref stats.OpenTicks))));
        }
        catch (Exception)
        {
            // A diagnostic must never fail a request.
        }
    }

    // The kind of request, from its path. The seeded tree is section /
    // category / page / detail, one path segment per level, so the depth names
    // the kind without knowing the content.
    public static string Classify(string method, string? path)
    {
        if (string.IsNullOrEmpty(path) || path == "/")
        {
            return "Home";
        }

        if (path.StartsWith("/umbraco/api/contactform", StringComparison.OrdinalIgnoreCase))
        {
            return HttpMethods.IsPost(method) ? "FormPost" : "SeederApi";
        }

        if (path.StartsWith("/umbraco/api/", StringComparison.OrdinalIgnoreCase))
        {
            return "SeederApi";
        }

        if (path.StartsWith("/media/", StringComparison.OrdinalIgnoreCase))
        {
            return "Media";
        }

        if (path.StartsWith("/umbraco", StringComparison.OrdinalIgnoreCase) || path.Contains('.'))
        {
            return "Other";
        }

        int segments = path.Split('/', StringSplitOptions.RemoveEmptyEntries).Length;
        return segments switch
        {
            1 => "Section",
            2 => "Category",
            3 => "Page",
            4 => "Detail",
            _ => "Other",
        };
    }

    // What each kind of request used since the previous call, in milliseconds.
    public static void DrainCost(List<(string Class, long Requests, long Ms, long SqlCommands, long SqlMs, long CommitMs)> costs)
    {
        foreach (KeyValuePair<string, long[]> entry in Cost)
        {
            long[] cost = entry.Value;
            long requests = Interlocked.Exchange(ref cost[0], 0);
            long ticks = Interlocked.Exchange(ref cost[1], 0);
            long sqlCommands = Interlocked.Exchange(ref cost[2], 0);
            long sqlTicks = Interlocked.Exchange(ref cost[3], 0);
            long commitTicks = Interlocked.Exchange(ref cost[4], 0);
            if (requests > 0)
            {
                costs.Add((entry.Key, requests, ToMs(ticks), sqlCommands, ToMs(sqlTicks), ToMs(commitTicks)));
            }
        }
    }

    // Each call returns what finished since the previous call.
    public static void Drain(out long slowCount, out long slowDropped, out long maxRequestMs, List<LoadTestSlowRequest> slowRequests)
    {
        slowCount = Interlocked.Exchange(ref _slowCount, 0);
        slowDropped = Interlocked.Exchange(ref _slowDropped, 0);
        maxRequestMs = Interlocked.Exchange(ref _maxRequestMs, 0);
        while (slowRequests.Count < MaxQueuedSlowRequests && SlowQueue.TryDequeue(out LoadTestSlowRequest? request))
        {
            slowRequests.Add(request);
        }
    }

    private static long ToMs(long stopwatchTicks) => stopwatchTicks * 1000 / Stopwatch.Frequency;
}

// Adds up, per request, the time spent in SQL commands, transaction commits
// and opening connections, from Microsoft.Data.SqlClient's diagnostic events.
// The events are raised on the calling code's own flow, so the request they
// belong to is the current one; work outside a request is ignored.
public sealed class LoadTestSqlTimings : IObserver<DiagnosticListener>, IObserver<KeyValuePair<string, object?>>, IDisposable
{
    private readonly List<IDisposable> _subscriptions = new();
    private IDisposable? _allListeners;

    public void Start() => _allListeners = DiagnosticListener.AllListeners.Subscribe(this);

    public void Dispose()
    {
        _allListeners?.Dispose();
        lock (_subscriptions)
        {
            foreach (IDisposable subscription in _subscriptions)
            {
                subscription.Dispose();
            }

            _subscriptions.Clear();
        }
    }

    void IObserver<DiagnosticListener>.OnNext(DiagnosticListener listener)
    {
        if (listener.Name == "SqlClientDiagnosticListener")
        {
            IDisposable subscription = listener.Subscribe(this);
            lock (_subscriptions)
            {
                _subscriptions.Add(subscription);
            }
        }
    }

    void IObserver<KeyValuePair<string, object?>>.OnNext(KeyValuePair<string, object?> diagnosticEvent)
    {
        try
        {
            LoadTestRequestStats? stats = LoadTestRequestTracker.Current;
            if (stats is null)
            {
                return;
            }

            // Names are "Microsoft.Data.SqlClient.WriteCommandBefore", "...After"
            // and "...Error", and the same for ConnectionOpen and
            // TransactionCommit.
            string name = diagnosticEvent.Key;
            bool before = name.EndsWith("Before", StringComparison.Ordinal);
            if (!before && !name.EndsWith("After", StringComparison.Ordinal) && !name.EndsWith("Error", StringComparison.Ordinal))
            {
                return;
            }

            long now = Stopwatch.GetTimestamp();
            if (name.Contains("WriteCommand", StringComparison.Ordinal))
            {
                if (before)
                {
                    Interlocked.Exchange(ref stats.CommandStartedAt, now);
                }
                else
                {
                    Stop(ref stats.CommandStartedAt, ref stats.SqlTicks, now);
                    Interlocked.Increment(ref stats.SqlCommands);
                }
            }
            else if (name.Contains("WriteTransactionCommit", StringComparison.Ordinal))
            {
                if (before)
                {
                    Interlocked.Exchange(ref stats.CommitStartedAt, now);
                }
                else
                {
                    Stop(ref stats.CommitStartedAt, ref stats.CommitTicks, now);
                }
            }
            else if (name.Contains("WriteConnectionOpen", StringComparison.Ordinal))
            {
                if (before)
                {
                    Interlocked.Exchange(ref stats.OpenStartedAt, now);
                }
                else
                {
                    Stop(ref stats.OpenStartedAt, ref stats.OpenTicks, now);
                }
            }
        }
        catch (Exception)
        {
            // A diagnostic must never fail a database call.
        }
    }

    private static void Stop(ref long startedAt, ref long total, long now)
    {
        long started = Interlocked.Exchange(ref startedAt, 0);
        if (started != 0)
        {
            Interlocked.Add(ref total, now - started);
        }
    }

    void IObserver<DiagnosticListener>.OnCompleted() { }

    void IObserver<DiagnosticListener>.OnError(Exception error) { }

    void IObserver<KeyValuePair<string, object?>>.OnCompleted() { }

    void IObserver<KeyValuePair<string, object?>>.OnError(Exception error) { }
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
            LoadTestRequestStats stats = LoadTestRequestTracker.Enter();
            try
            {
                await nextMiddleware(context);
            }
            finally
            {
                LoadTestRequestTracker.Leave(stats, context);
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
    private LoadTestSqlTimings? _sqlTimings;

    // Per-thread CPU at the previous beat, to name the threads that used most
    // since. Null once reading it has failed (the App Service sandbox may not
    // allow it): the field is then logged as "n/a".
    private Dictionary<int, double>? _threadCpu = new();

    // Names of assemblies loaded since the previous beat (see asm_n).
    private readonly ConcurrentQueue<string> _loadedAssemblies = new();
    private AssemblyLoadEventHandler? _assemblyLoadHandler;

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
        try
        {
            _sqlTimings = new LoadTestSqlTimings();
            _sqlTimings.Start();
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "LoadTestHeartbeat could not listen to SQL client events; sql_n, sql_ms, commit_ms and open_ms will read 0");
        }
        _assemblyLoadHandler = (_, args) =>
        {
            if (_loadedAssemblies.Count < 500)
            {
                _loadedAssemblies.Enqueue(args.LoadedAssembly.GetName().Name ?? "?");
            }
        };
        AppDomain.CurrentDomain.AssemblyLoad += _assemblyLoadHandler;
        ThreadPool.GetMinThreads(out int minWorkers, out int minIo);
        _logger.LogInformation(
            "LoadTestHeartbeat started: {Bitness}-bit process, server GC {ServerGc}, {Cores} cores, processor {Processor}, pool minimum {MinWorkers} worker / {MinIo} IO threads, share path {SharePath}, local path {LocalPath}",
            Environment.Is64BitProcess ? 64 : 32, System.Runtime.GCSettings.IsServerGC, Environment.ProcessorCount,
            // The same plan size can sit on different hardware from one build to
            // the next, and time per request follows the processor. Recorded so
            // two runs can be told apart on it.
            Environment.GetEnvironmentVariable("PROCESSOR_IDENTIFIER") ?? "unknown", minWorkers, minIo, _sharePath, _localPath);
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        _stop.Set();
        return Task.CompletedTask;
    }

    public void Dispose()
    {
        if (_assemblyLoadHandler is not null)
        {
            AppDomain.CurrentDomain.AssemblyLoad -= _assemblyLoadHandler;
        }
        _runtimeEvents?.Dispose();
        _sqlTimings?.Dispose();
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
                .Select(t => $"{t.Id}:{t.Ms}:{ThreadName(t.Id)}"));
            return top.Length > 0 ? top : "-";
        }
        catch (Exception)
        {
            _threadCpu = null;
            return "n/a";
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenThread(uint desiredAccess, bool inheritHandle, uint threadId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int GetThreadDescription(IntPtr thread, out IntPtr description);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr memory);

    private bool _threadNamesFailed;

    // The name a thread was given (.NET passes Thread.Name on to Windows), with
    // spaces as underscores so the field stays one token. "?" when there is
    // none, the platform has no such call, or the sandbox refuses it.
    private string ThreadName(int threadId)
    {
        if (_threadNamesFailed || !OperatingSystem.IsWindows())
        {
            return "?";
        }

        try
        {
            const uint ThreadQueryLimitedInformation = 0x0800;
            IntPtr handle = OpenThread(ThreadQueryLimitedInformation, false, (uint)threadId);
            if (handle == IntPtr.Zero)
            {
                return "?";
            }

            try
            {
                if (GetThreadDescription(handle, out IntPtr description) < 0 || description == IntPtr.Zero)
                {
                    return "?";
                }

                try
                {
                    string? name = Marshal.PtrToStringUni(description);
                    return string.IsNullOrWhiteSpace(name) ? "?" : name.Replace(' ', '_').Replace(',', '_').Replace(':', '_');
                }
                finally
                {
                    LocalFree(description);
                }
            }
            finally
            {
                CloseHandle(handle);
            }
        }
        catch (Exception)
        {
            _threadNamesFailed = true;
            return "?";
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
        long lastJit = System.Runtime.JitInfo.GetCompiledMethodCount();
        TimeSpan minuteCpu = Environment.CpuUsage.TotalTime;
        long minuteAllocated = GC.GetTotalAllocatedBytes(false);
        int minuteGen0 = GC.CollectionCount(0), minuteGen1 = GC.CollectionCount(1), minuteGen2 = GC.CollectionCount(2);
        var costs = new List<(string Class, long Requests, long Ms, long SqlCommands, long SqlMs, long CommitMs)>();
        var assemblyNames = new List<string>();
        long maxCpu = 0, maxContention = 0, sumStarvation = 0, sumContentions = 0;
        long maxOldest = 0, maxRequest = 0, sumSlowRequests = 0;
        var slowRequests = new List<LoadTestSlowRequest>();

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
            long oldestMs = LoadTestRequestTracker.OldestMs;
            slowRequests.Clear();
            LoadTestRequestTracker.Drain(out long slowCount, out long slowDropped, out long maxRequestMs, slowRequests);
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
            long jitNow = System.Runtime.JitInfo.GetCompiledMethodCount();
            long jitMethods = jitNow - lastJit;
            lastJit = jitNow;
            assemblyNames.Clear();
            while (_loadedAssemblies.TryDequeue(out string? assemblyName))
            {
                assemblyNames.Add(assemblyName);
            }

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
            maxOldest = Math.Max(maxOldest, oldestMs); maxRequest = Math.Max(maxRequest, maxRequestMs); sumSlowRequests += slowCount;
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
                || gcPauseMs >= GcPauseMs || stuckMs >= StuckMs || oldestMs >= StuckMs || shareFailed || localFailed || sqlFailed || sqlBlockedWaitMs >= StuckMs;
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
                "LoadTestHeartbeat beat: late_ms={LateMs} gap_ms={GapMs} cpu_ms={CpuMs} cpu_span_ms={CpuSpanMs} top_threads={TopThreads} gc_pause_ms={GcPauseMs} gen0={Gen0} gen1={Gen1} gen2={Gen2} gc2={Gc2Starts} gc_reason={GcReason} contention_n={Contentions} contention_max_ms={ContentionMaxMs} starvation={Starvation} pool_ms={PoolMs} pool_threads={PoolThreads} pool_pending={PoolPending} share_ms={ShareMs} share_failed={ShareFailed} local_ms={LocalMs} local_failed={LocalFailed} sql_ms={SqlMs} sql_failed={SqlFailed} sql_blocked={SqlBlocked} sql_blocked_wait_ms={SqlBlockedWaitMs} in_flight={InFlight} stuck_ms={StuckMs} oldest_ms={OldestMs} started={Started} completed={Completed} slow_n={SlowRequests} max_req_ms={MaxRequestMs} jit_n={JitMethods} asm_n={AssembliesLoaded} heap_mb={HeapMb}",
                lateMs, gapMs, cpuMs, cpuSpanMs, topThreads, gcPauseMs, dGen0, dGen1, dGen2, gen2Starts, gcReason, contentions, contentionMaxMs, starvation, poolMs, poolThreads, poolPending, shareMs, shareFailed, localMs, localFailed, sqlMs, sqlFailed, sqlBlocked, sqlBlockedWaitMs, inFlight, stuckMs, oldestMs, dStarted, dCompleted, slowCount, maxRequestMs, jitMethods, assemblyNames.Count, GC.GetTotalMemory(false) / (1024 * 1024));

            if (assemblyNames.Count > 0)
            {
                _logger.LogInformation(
                    "LoadTestHeartbeat assemblies loaded: n={Count} names={Names}",
                    assemblyNames.Count, string.Join(',', assemblyNames.Take(25)));
            }

            // One line per request that spent SlowRequestMs or more inside the
            // app. Written here, not on the request's thread; ended_utc is when
            // the request ended, up to a beat before this line's own timestamp.
            foreach (LoadTestSlowRequest request in slowRequests)
            {
                _logger.LogInformation(
                    "LoadTestHeartbeat slow request: ended_utc={EndedUtc} ms={Ms} method={Method} path={Path} status={Status} in_flight_at_start={InFlightAtStart} sql_n={SqlCommands} sql_ms={SqlMs} commit_ms={CommitMs} open_ms={OpenMs}",
                    request.EndedUtc.ToString("HH:mm:ss.fff", System.Globalization.CultureInfo.InvariantCulture), request.Ms, request.Method, request.Path, request.Status, request.InFlightAtStart, request.SqlCommands, request.SqlMs, request.CommitMs, request.OpenMs);
            }

            if (slowDropped > 0)
            {
                _logger.LogWarning("LoadTestHeartbeat dropped {Dropped} slow request line(s): more than the queue holds finished within one beat", slowDropped);
            }

            // By the clock, not by beat count: beats stop while a probe hangs.
            if (now - summaryFrom >= SummaryEveryMs)
            {
                _logger.LogInformation(
                    "LoadTestHeartbeat minute: seconds={Seconds} beats={Beats} slow_beats={SlowBeats} failed_probes={FailedProbes} max_cpu_ms={MaxCpuMs} contentions={Contentions} max_contention_ms={MaxContentionMs} starvation={Starvation} max_late_ms={MaxLateMs} max_gap_ms={MaxGapMs} max_gc_pause_ms={MaxGcPauseMs} gen0={Gen0} gen1={Gen1} gen2={Gen2} max_pool_ms={MaxPoolMs} pool_threads={PoolThreads} max_share_ms={MaxShareMs} max_local_ms={MaxLocalMs} max_sql_ms={MaxSqlMs} max_sql_blocked={MaxSqlBlocked} max_sql_blocked_wait_ms={MaxSqlBlockedWaitMs} max_in_flight={MaxInFlight} max_stuck_ms={MaxStuckMs} max_oldest_ms={MaxOldestMs} started={Started} completed={Completed} slow_requests={SlowRequests} max_req_ms={MaxRequestMs} heap_mb={HeapMb}",
                    (now - summaryFrom) / 1000, beats, slowBeats, failedProbes, maxCpu, sumContentions, maxContention, sumStarvation, maxLate, maxGap, maxGc, sumGen0, sumGen1, sumGen2, maxPool, ThreadPool.ThreadCount, maxShare, maxLocal, maxSql, maxBlocked, maxBlockedWait, maxInFlight, maxStuck, maxOldest, minuteStarted, minuteCompleted, sumSlowRequests, maxRequest, GC.GetTotalMemory(false) / (1024 * 1024));
                maxLate = maxPool = maxShare = maxLocal = maxSql = maxGc = maxInFlight = maxStuck = maxGap = maxBlocked = maxBlockedWait = minuteStarted = minuteCompleted = 0;
                beats = slowBeats = failedProbes = sumGen0 = sumGen1 = sumGen2 = 0;
                maxCpu = maxContention = sumStarvation = sumContentions = 0;
                // What the minute cost: per kind of request, and for the process.
                costs.Clear();
                LoadTestRequestTracker.DrainCost(costs);
                long costRequests = 0;
                foreach ((string costClass, long costCount, long costMs, long costSqlCommands, long costSqlMs, long costCommitMs) in costs.OrderBy(c => c.Class, StringComparer.Ordinal))
                {
                    costRequests += costCount;
                    _logger.LogInformation(
                        "LoadTestHeartbeat cost: class={Class} n={Requests} ms={Ms} sql_n={SqlCommands} sql_ms={SqlMs} commit_ms={CommitMs}",
                        costClass, costCount, costMs, costSqlCommands, costSqlMs, costCommitMs);
                }

                TimeSpan cpuTotal = Environment.CpuUsage.TotalTime;
                long allocated = GC.GetTotalAllocatedBytes(false);
                _logger.LogInformation(
                    "LoadTestHeartbeat cost total: requests={Requests} cpu_ms={CpuMs} alloc_mb={AllocMb} gen0={Gen0} gen1={Gen1} gen2={Gen2}",
                    costRequests, (long)(cpuTotal - minuteCpu).TotalMilliseconds, (allocated - minuteAllocated) / (1024 * 1024),
                    gen0 - minuteGen0, gen1 - minuteGen1, gen2 - minuteGen2);
                minuteGen0 = gen0; minuteGen1 = gen1; minuteGen2 = gen2;
                minuteCpu = cpuTotal;
                minuteAllocated = allocated;

                maxOldest = maxRequest = sumSlowRequests = 0;
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
