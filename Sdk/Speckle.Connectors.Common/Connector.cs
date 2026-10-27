using System.Reflection;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Speckle.Connectors.Common.Common;
using Speckle.Connectors.Common.Credentials;
using Speckle.Connectors.Logging;
using Speckle.Objects.Geometry;
using Speckle.Sdk;
using Speckle.Sdk.Credentials;

namespace Speckle.Connectors.Common;

public static class Connector
{
  private sealed record LoggingDisposable(IDisposable Logging, IDisposable Tracing, IDisposable Metrics) : IDisposable
  {
    public void Dispose()
    {
      Logging.Dispose();
      Tracing.Dispose();
      Metrics.Dispose();
    }
  }

  public static readonly string TabName = "BIM Station";
  public static readonly string TabTitle = "BIM Station";

  public static IDisposable Initialize(
    this IServiceCollection serviceCollection,
    Application application,
    HostAppVersion version
  )
  {
    var assemblyVersion = Assembly.GetExecutingAssembly().GetVersion();
    serviceCollection.AddSpeckleSdk(
      application,
      HostApplications.GetVersion(version),
      assemblyVersion,
      typeof(Point).Assembly
    );
    // BIM Station: our sign-in page instead of the SDK's "Speckle Connector" one. Registered after
    // AddSpeckleSdk (which uses TryAdd) so this registration is the one that resolves.
    serviceCollection.AddTransient<IAuthFlow, BimStationAuthFlow>();

    return serviceCollection.AddOpenTelemetry(
      "Connector",
      application,
      version,
#if DEBUG || LOCAL
      new SpeckleLogging(Console: true, File: new(), MinimumLevel: SpeckleLogLevel.Debug),
      new SpeckleTracing(Console: false),
      new SpeckleMetrics(Console: false)
#else
      // Telemetry export removed for BIM Station builds: the upstream Release path
      // shipped logs and traces to a third-party endpoint with a hardcoded key.
      // Local console and file logging are kept.
      new SpeckleLogging(Console: true, File: new(), MinimumLevel: SpeckleLogLevel.Information),
      new SpeckleTracing(Console: false),
      null
#endif
    );
  }

  public static IDisposable AddOpenTelemetry(
    this IServiceCollection serviceCollection,
    string serviceName,
    Application application,
    HostAppVersion version,
    SpeckleLogging loggingConfig,
    SpeckleTracing? tracingConfig,
    SpeckleMetrics? metricsConfig
  )
  {
    var assemblyVersion = Assembly.GetExecutingAssembly().GetVersion();
    var (logging, tracing, metrics) = Observability.Initialize(
      serviceName,
      application.Name + " " + HostApplications.GetVersion(version),
      application.Slug,
      assemblyVersion,
      new(loggingConfig, tracingConfig, metricsConfig)
    );
    //do this after the AddSpeckleSdk so that the logging system gets values from here.
    serviceCollection.AddLogging(x =>
    {
      x.ClearProviders();
      x.AddProvider(new SpeckleLogProvider(logging));
      x.SetMinimumLevel(GetMicrosoftLevel(loggingConfig.MinimumLevel));
    });
    serviceCollection.AddSingleton<Speckle.Sdk.Logging.ISdkActivityFactory, ConnectorActivityFactory>();
    return new LoggingDisposable(logging, tracing, metrics);
  }

  private static LogLevel GetMicrosoftLevel(SpeckleLogLevel speckleLogLevel) =>
    speckleLogLevel switch
    {
      SpeckleLogLevel.Debug => LogLevel.Debug,
      SpeckleLogLevel.Verbose => LogLevel.Trace,
      SpeckleLogLevel.Information => LogLevel.Information,
      SpeckleLogLevel.Warning => LogLevel.Warning,
      SpeckleLogLevel.Error => LogLevel.Error,
      SpeckleLogLevel.Fatal => LogLevel.Critical,
      _ => throw new ArgumentOutOfRangeException(nameof(speckleLogLevel), speckleLogLevel, null),
    };
}
