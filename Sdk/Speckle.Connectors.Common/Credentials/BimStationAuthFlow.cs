using System.Diagnostics;
using System.Net;
#if NETFRAMEWORK
using System.Net.Http;
#endif
using System.Net.Http.Headers;
using System.Text;
using Speckle.Newtonsoft.Json;
using Speckle.Sdk.Common;
using Speckle.Sdk.Credentials;
using Speckle.Sdk.Helpers;
using Speckle.Sdk.Logging;

namespace Speckle.Connectors.Common.Credentials;

/// <summary>
/// BIM Station's browser sign-in. Same protocol as the SDK's <see cref="AuthFlow"/> (PKCE, the same
/// endpoints and callback port), but the page the browser lands on after authorizing is ours: the
/// SDK hardcodes "Your Speckle Connector is now authorized", which users see.
/// </summary>
/// <remarks>
/// Registered over the SDK's implementation in <see cref="Connector.Initialize"/>. Token refresh is
/// delegated to the SDK unchanged. When upgrading Speckle.Sdk, diff its AuthFlow against this class.
/// </remarks>
public sealed class BimStationAuthFlow(ISdkActivityFactory activityFactory, ISpeckleHttp speckleHttp) : IAuthFlow
{
  private readonly AuthFlow _sdkAuthFlow = new(activityFactory, speckleHttp);

  private readonly JsonSerializerSettings _serializerSettings = new()
  {
    MissingMemberHandling = MissingMemberHandling.Error,
    NullValueHandling = NullValueHandling.Ignore,
  };

  public async Task<TokenExchangeResponse> TriggerAuthFlowWithTimeout(
    Uri serverUrl,
    AuthApp authApp,
    TimeSpan timeout,
    CancellationToken cancellationToken
  )
  {
    using HttpClient client = speckleHttp.CreateHttpClient();

    Uri tokenEndpoint = new(serverUrl, "/oauth/token");
    string codeVerifier = AuthFlow.GenerateCodeVerifier();
    Uri authnVerify;
    using var req = await client.GetAsync(tokenEndpoint, cancellationToken).ConfigureAwait(false);
    bool useLegacyEndpoint = req.StatusCode != HttpStatusCode.OK;

    if (useLegacyEndpoint)
    {
      string challenge = codeVerifier; // Old endpoint only supports PKCE "plain" method
      authnVerify = new($"/authn/verify/{authApp.AppId}/{challenge}", UriKind.Relative);
      tokenEndpoint = new(serverUrl, "/auth/token");
    }
    else
    {
      string challenge = AuthFlow.GenerateCodeChallenge(codeVerifier);
      authnVerify = new($"/authn/verify/{authApp.AppId}/{challenge}?code_challenge_method=S256", UriKind.Relative);
    }

    Uri endpoint = new(serverUrl, authnVerify);
    _ = Process.Start(new ProcessStartInfo(endpoint.ToString()) { UseShellExecute = true });
    string accessCode = await RunListenerWithTimeout(authApp.CallbackUrl, timeout, cancellationToken)
      .ConfigureAwait(false);

    object body = useLegacyEndpoint
      ? new
      {
        appId = authApp.AppId,
        appSecret = authApp.AppSecret,
        accessCode,
        challenge = codeVerifier,
      }
      : new
      {
        appId = authApp.AppId,
        accessCode,
        codeVerifier,
      };

    using StringContent content = new(JsonConvert.SerializeObject(body, _serializerSettings));
    content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
    using HttpResponseMessage response = await client
      .PostAsync(tokenEndpoint, content, cancellationToken)
      .ConfigureAwait(false);
    response.EnsureSuccessStatusCode();

#if NET8_0_OR_GREATER
    string read = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
#else
    string read = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
#endif
    return JsonConvert.DeserializeObject<TokenExchangeResponse>(read, _serializerSettings).NotNull();
  }

  /// <exception cref="OperationCanceledException"><paramref name="userCancellation"/> requested cancel</exception>
  /// <exception cref="TimeoutException">timeout was reached</exception>
  public async Task<string> RunListenerWithTimeout(
    Uri applicationCallbackUrl,
    TimeSpan timeout,
    CancellationToken userCancellation
  )
  {
    using CancellationTokenSource cancelOnTimeout = new(timeout);
    using CancellationTokenSource linkedSource = CancellationTokenSource.CreateLinkedTokenSource(
      cancelOnTimeout.Token,
      userCancellation
    );

    try
    {
      using var activity = activityFactory.Start("Listening for authflow access code");

      return await RunListener(applicationCallbackUrl, linkedSource.Token).ConfigureAwait(false);
    }
    catch (OperationCanceledException) when (userCancellation.IsCancellationRequested)
    {
      throw;
    }
    catch (OperationCanceledException ex) when (cancelOnTimeout.IsCancellationRequested)
    {
      throw new TimeoutException($"Auth flow was cancelled after {timeout:g} timeout", ex);
    }
  }

  public Task<TokenExchangeResponse> GetRefreshedToken(
    string? refreshToken,
    Uri serverUrl,
    AuthApp authApp,
    CancellationToken cancellationToken
  ) => _sdkAuthFlow.GetRefreshedToken(refreshToken, serverUrl, authApp, cancellationToken);

  private static async Task<HttpListenerContext> GetContext(HttpListener listener, CancellationToken cancellationToken)
  {
    //GetContextAsync doesn't support cancellation, so we have to do this song and dance...
    Task timeoutTask = Task.Delay(Timeout.Infinite, cancellationToken);
    Task<HttpListenerContext> getContextTask = listener.GetContextAsync();

    Task completed = await Task.WhenAny(getContextTask, timeoutTask).ConfigureAwait(false);
    if (completed == getContextTask)
    {
      return await getContextTask.ConfigureAwait(false);
    }

    cancellationToken.ThrowIfCancellationRequested();

    throw new InvalidOperationException("Cancellation should have thrown, this shouldn't be possible");
  }

  private static async Task<string> RunListener(Uri localUrl, CancellationToken cancellationToken)
  {
    using HttpListener listener = new();
    listener.Prefixes.Add(localUrl.ToString());
    listener.Start();

    HttpListenerContext context = await GetContext(listener, cancellationToken).ConfigureAwait(false);
    HttpListenerRequest request = context.Request;
    using HttpListenerResponse response = context.Response;

    string? accessCode = request.QueryString["access_code"];
    bool isDenied = request.QueryString["denied"] == "true";

    if (isDenied)
    {
      WritePage(
        response,
        "Sign-in cancelled",
        "Access to your BIM Station account was not granted. You can close this tab and try again from the BIM Station panel in Revit."
      );
      throw new AuthFlowException("Authentication flow was denied"); //denied presumably by the user
    }

    if (accessCode != null)
    {
      WritePage(
        response,
        "You're signed in",
        "BIM Station for Revit is now connected to your account. You can close this tab and go back to Revit."
      );
      return accessCode;
    }

    WritePage(
      response,
      "Sign-in failed",
      "Something went wrong while connecting BIM Station for Revit. Close this tab and try again from the BIM Station panel in Revit."
    );
    throw new AuthFlowException("Failed to receive access code");
  }

  /// <summary>Styled after the BIM Station web app's sign-in card</summary>
  private static void WritePage(HttpListenerResponse response, string title, string message)
  {
    string html = $$"""
      <!doctype html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>{{WebUtility.HtmlEncode(title)}} · BIM Station</title>
        <style>
          body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
                 background: #f1f2f4; color: #161a1f; font: 13px/1.5 Arial, Helvetica, "Liberation Sans", sans-serif; }
          .wrap { width: 100%; max-width: 370px; padding: 16px; box-sizing: border-box; }
          .brand { display: flex; align-items: center; justify-content: center; gap: 8px; margin-bottom: 16px; }
          .mark { width: 26px; height: 26px; border-radius: 6px; background: #2fa866; color: #fff; font-weight: 700;
                  font-size: 13.5px; display: flex; align-items: center; justify-content: center; }
          .name { font-size: 16px; font-weight: 600; letter-spacing: 0.02em; }
          .card { background: #fff; border: 1px solid #e4e6ea; border-radius: 10px; padding: 22px 24px 20px; }
          h1 { margin: 0 0 4px; font-size: 16px; font-weight: 600; }
          p { margin: 0; color: #5b626c; }
        </style>
      </head>
      <body>
        <div class="wrap">
          <div class="brand"><div class="mark">B</div><div class="name">BIM Station</div></div>
          <div class="card">
            <h1>{{WebUtility.HtmlEncode(title)}}</h1>
            <p>{{WebUtility.HtmlEncode(message)}}</p>
          </div>
        </div>
      </body>
      </html>
      """;

    byte[] buffer = Encoding.UTF8.GetBytes(html);
    response.ContentType = "text/html; charset=utf-8";
    response.ContentLength64 = buffer.Length;
    response.OutputStream.Write(buffer, 0, buffer.Length);
  }
}
