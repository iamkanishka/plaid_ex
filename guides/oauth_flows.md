# OAuth Flows

Many major US financial institutions (Chase, Wells Fargo, Capital One, Bank of America,
Citibank, and others) require OAuth authorization through their own banking portal
rather than credential entry within Plaid Link.

## How OAuth works with Plaid

```
1. Your server creates a Link token with redirect_uri
2. User opens Plaid Link in your app
3. User selects an OAuth institution (e.g., Chase)
4. Plaid redirects the user to Chase's OAuth portal
5. User authorizes at Chase (MFA, account selection)
6. Chase redirects back to your redirect_uri with oauth_state_id
7. Your app re-initializes Plaid Link with the oauth_state_id
8. Plaid Link completes and gives you a public_token
9. You exchange public_token for access_token
```

## Web (desktop) OAuth flow

### Step 1: Create Link token with redirect_uri

```elixir
defmodule MyAppWeb.PlaidController do
  def create_link_token(conn, _params) do
    user = conn.assigns.current_user

    {:ok, result} = PlaidEx.initiate_oauth(
      user_id: to_string(user.id),
      products: ["transactions"],
      country_codes: ["US"],
      redirect_uri: "https://yourapp.com/oauth/plaid/callback",
      language: "en"
    )

    # Store oauth_state server-side — it's already in PlaidEx.OAuth.StateStore
    # The state is identified by result.oauth_state

    json(conn, %{
      link_token: result.link_token,
      oauth_state: result.oauth_state   # pass to frontend for round-trip
    })
  end
end
```

### Step 2: Frontend — initialize Link and handle redirect

```javascript
import { usePlaidLink } from 'react-plaid-link';

function ConnectBankOAuth({ linkToken, oauthState, onSuccess }) {
  const { open } = usePlaidLink({
    token: linkToken,
    onSuccess: (publicToken) => {
      // This fires AFTER the OAuth redirect completes
      onSuccess(publicToken);
    },
    // For OAuth redirect flow, receivedRedirectUri is set
    // after the user returns from the bank's portal
    receivedRedirectUri: window.location.href,
  });

  // Open Link immediately after component mounts
  // (for the second initialization after OAuth redirect)
  useEffect(() => {
    if (isOAuthRedirect()) {
      open();
    }
  }, []);

  return <button onClick={open}>Connect Bank</button>;
}

function isOAuthRedirect() {
  return window.location.href.includes('oauth_state_id');
}
```

### Step 3: Handle the OAuth redirect

```elixir
# router.ex
get "/oauth/plaid/callback", PlaidController, :oauth_callback

# controller
def oauth_callback(conn, params) do
  # Plaid redirects here with ?oauth_state_id=...
  oauth_state_id = params["oauth_state_id"]

  if oauth_state_id do
    # Verify state is valid (stored in PlaidEx.OAuth.StateStore)
    case PlaidEx.OAuth.StateStore.peek(oauth_state_id) do
      {:ok, state_data} ->
        # State is valid — render the page that re-initializes Link
        # with the same link_token and receivedRedirectUri
        render(conn, "oauth_callback.html",
          oauth_state_id: oauth_state_id,
          user_id: state_data[:user_id]
        )

      {:error, :not_found} ->
        redirect(conn, to: "/error?reason=invalid_oauth_state")

      {:error, :expired} ->
        redirect(conn, to: "/error?reason=oauth_state_expired")
    end
  else
    redirect(conn, to: "/dashboard")
  end
end
```

### Step 4: Exchange the public token

```elixir
# Called from your frontend after Link completes
def exchange_token(conn, %{"public_token" => public_token, "oauth_state_id" => state_id}) do
  case PlaidEx.complete_oauth(
    oauth_state_id: state_id,
    public_token: public_token
  ) do
    {:ok, %{access_token: access_token, item_id: item_id}} ->
      user = conn.assigns.current_user

      # Store the access token
      MyApp.PlaidItems.create!(%{
        user_id: user.id,
        item_id: item_id,
        access_token: MyApp.Vault.encrypt!(access_token)
      })

      json(conn, %{success: true})

    {:error, %PlaidEx.Error{code: "INVALID_OAUTH_STATE"}} ->
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Invalid OAuth state — possible CSRF"})

    {:error, %PlaidEx.Error{code: "EXPIRED_OAUTH_STATE"}} ->
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Session expired — please try again"})

    {:error, error} ->
      conn
      |> put_status(:internal_server_error)
      |> json(%{error: error.message})
  end
end
```

## Mobile OAuth (deep links)

For mobile apps (iOS/Android), use deep link URIs instead of HTTPS redirect URIs:

```elixir
# iOS example
{:ok, result} = PlaidEx.initiate_oauth(
  user_id: user_id,
  products: ["transactions"],
  country_codes: ["US"],
  redirect_uri: "myapp://plaid/oauth",  # deep link
  language: "en"
)
```

On iOS, register the URL scheme in `Info.plist`:
```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>myapp</string>
    </array>
  </dict>
</array>
```

On Android, register in `AndroidManifest.xml`:
```xml
<intent-filter>
  <action android:name="android.intent.action.VIEW" />
  <category android:name="android.intent.category.DEFAULT" />
  <category android:name="android.intent.category.BROWSABLE" />
  <data android:scheme="myapp" android:host="plaid" android:path="/oauth" />
</intent-filter>
```

## PKCE in detail

PlaidEx generates PKCE pairs automatically for all OAuth flows:

```elixir
# Manually generate a PKCE pair if needed
pkce = PlaidEx.OAuth.PKCE.generate()
# %PlaidEx.OAuth.PKCE{
#   code_verifier: "abc123...",     # 32-byte base64url random
#   code_challenge: "xyz789...",    # SHA-256(verifier), base64url
#   challenge_method: "S256"
# }
```

The `code_verifier` is stored in `PlaidEx.OAuth.StateStore` by `oauth_state`.
The `code_challenge` is passed to Plaid in the Link token request.

## Security properties

**State validation:**
- Each OAuth state is a cryptographically random 32-byte token
- States are single-use (consumed on retrieval)
- States expire after 10 minutes (configurable)
- Prevents CSRF attacks — state must match between initiation and completion

**PKCE:**
- Prevents authorization code interception attacks
- `code_verifier` is never transmitted; only its SHA-256 hash is sent
- Plaid verifies the verifier matches the challenge on code exchange

## Troubleshooting OAuth

### "oauth_state_id not found"

**Cause:** State was consumed, expired, or the user opened a second tab.

**Fix:** Re-initiate the OAuth flow (create a new Link token).

**Prevention:** Increase TTL if users take > 10 minutes to complete OAuth:
```elixir
Application.put_env(:plaid_ex, :oauth_state_ttl_seconds, 1800)  # 30 minutes
```

### "redirect_uri not in allowed list"

**Cause:** The `redirect_uri` in your Link token request doesn't match
what's registered in the Plaid Dashboard.

**Fix:** Go to Plaid Dashboard → API → Allowed redirect URIs and add
your exact redirect URI (must match character-for-character, including
trailing slash).

### OAuth loop (user keeps getting redirected)

**Cause:** The `receivedRedirectUri` is not being passed to Plaid Link
on the second initialization.

**Fix:** On your callback page, re-initialize Link with:
```javascript
const { open } = usePlaidLink({
  token: linkToken,               // same token from step 1
  receivedRedirectUri: window.location.href,  // the full callback URL
  onSuccess: handleSuccess
});
```

### Institution not showing OAuth flow

Not all institutions require OAuth. Plaid shows OAuth institutions automatically
when `redirect_uri` is provided in the Link token. Institutions without OAuth
will show the standard credential entry flow.

## Testing OAuth in sandbox

Plaid's sandbox supports OAuth testing:

```elixir
# Create a Link token for an OAuth institution
{:ok, result} = PlaidEx.initiate_oauth(
  user_id: "test-user",
  products: ["transactions"],
  country_codes: ["US"],
  redirect_uri: "https://localhost:4000/oauth/plaid/callback",
  language: "en"
)

# In Plaid Link sandbox, select "Platypus OAuth Bank" (ins_127287)
# It simulates the full OAuth redirect flow
```

For automated tests, you can mock the OAuth flow:

```elixir
# In tests, skip the browser redirect entirely
oauth_state = PlaidEx.OAuth.StateStore.put(%{
  user_id: "test-user",
  tenant_id: nil,
  redirect_uri: "https://localhost/callback"
})

# Simulate completion (as if user returned from bank's OAuth)
{:ok, result} = PlaidEx.complete_oauth(
  oauth_state_id: oauth_state,
  public_token: "public-sandbox-test-token"
)
```
