from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    app_name: str = "Wo Backend"
    debug: bool = False

    database_url: str = "postgresql+asyncpg://postgres:postgres@localhost:5432/wo"
    database_url_sync: str = "postgresql+psycopg://postgres:postgres@localhost:5432/wo"

    # Used to build invitation links + deep-link payloads. Override per env.
    web_base_url: str = "https://wo.app"
    deep_link_scheme: str = "wo"

    # Where uploaded files (photos, attachments) land on disk in dev. Production
    # will swap this for an S3-style backend via `app.core.storage`.
    storage_root: str = "./storage"

    # Per-upload size cap, bytes. 20 MB covers reasonable family photos.
    max_upload_bytes: int = 20 * 1024 * 1024

    # Memory plugin accepts short videos alongside photos; clips run larger than
    # stills, so video media gets its own (more generous) cap.
    memory_video_max_bytes: int = 100 * 1024 * 1024

    # ---- In-app update (Android APK) --------------------------------------
    # Shared secret guarding `POST /app/release`. Empty = publishing disabled
    # (the endpoint 403s). Set it in /etc/wo/app.env on the server; the publish
    # script sends it as the `X-Release-Token` header.
    app_release_token: str = ""
    # Upload cap for the published APK. Release builds run larger than photos,
    # so this gets its own (generous) limit, separate from max_upload_bytes.
    app_release_max_bytes: int = 200 * 1024 * 1024

    # ---- COS (腾讯云对象存储) for APK distribution ------------------------
    # When `cos_bucket` is set, published APKs upload to COS and clients fetch
    # them directly from the COS public domain — offloading download bandwidth
    # from the single CVM. Left blank in dev/tests so the local-disk fallback
    # path keeps working unchanged.
    cos_bucket: str = ""            # e.g. wo-app-1258101097 (含 APPID 后缀)
    cos_region: str = ""            # e.g. ap-shanghai
    cos_secret_id: str = ""         # CAM 子账号 SecretId
    cos_secret_key: str = ""        # CAM 子账号 SecretKey
    # APK objects land under this prefix in the bucket. Trailing slash optional;
    # the cos client normalises it.
    cos_apk_prefix: str = "app-release"

    # Login throttling within the window (seconds). Per-IP guards against
    # enumeration/bulk registration; per-phone guards a single number against
    # targeting (and SMS bombing once P5 adds codes).
    login_rate_limit_max: int = 10
    login_rate_limit_per_phone_max: int = 5
    login_rate_limit_window_seconds: int = 60

    # ---- Session tokens / request auth ------------------------------------
    # Login mints an opaque bearer token valid for this long (see
    # app.services.session). 90 days keeps a family from re-logging-in often.
    session_ttl_days: int = 90
    # The legacy dev shim: when True, requests may authenticate via the
    # `X-User-Id` header (and default to the seed user when absent). Kept True
    # for dev/tests; set AUTH_DEV_SHIM_ENABLED=false in production so only real
    # bearer tokens are accepted and X-User-Id can't be forged.
    auth_dev_shim_enabled: bool = True

    # ---- Push (JPush / 极光推送) -------------------------------------------
    # Master switch. When false: notifications skip outbox staging and the
    # dispatcher loop never starts — so dev/tests behave exactly as before push.
    push_enabled: bool = False
    # JPush app credentials (Push API v3 uses HTTP Basic: app_key:master_secret).
    # Left blank in dev/tests; the client no-ops when either is empty.
    jpush_app_key: str = ""
    jpush_master_secret: str = ""
    jpush_api_url: str = "https://api.jpush.cn/v3/push"
    # iOS APNs gateway: false = sandbox (dev builds), true = production.
    jpush_apns_production: bool = False
    # Dispatcher tuning.
    push_poll_interval_seconds: float = 5.0
    push_batch_size: int = 100
    push_max_attempts: int = 5

    # ---- Anniversary reminders --------------------------------------------
    # Background loop that emits "anniversary due" notifications. Off by default
    # (like push) so dev/tests don't run it; enable per env. The check is
    # idempotent per occurrence, so polling hourly just makes delivery timely.
    anniversary_reminder_enabled: bool = False
    anniversary_reminder_poll_seconds: float = 3600.0

    # ---- Accounting month-end reminder ------------------------------------
    # Background loop that, on each month's last day at 21:00 Asia/Shanghai,
    # nudges families with the accounting plugin to review their balance. Off by
    # default; idempotent per month so hourly polling is fine.
    accounting_monthly_notice_enabled: bool = False
    accounting_monthly_notice_poll_seconds: float = 3600.0

    # ---- Stock weekly inventory reminder ----------------------------------
    # Background loop that, every Saturday at 20:00 Asia/Shanghai, nudges
    # families with the stock plugin to do a weekly inventory count. Off by
    # default; idempotent per Saturday so hourly polling is fine.
    stock_weekly_notice_enabled: bool = False
    stock_weekly_notice_poll_seconds: float = 3600.0

    # ---- Calendar (家历) due reminders ------------------------------------
    # Background loop that emits "calendar due" notifications ahead of each
    # item's next occurrence. Off by default; idempotent per occurrence, so
    # polling hourly just makes delivery timely.
    calendar_reminder_enabled: bool = False
    calendar_reminder_poll_seconds: float = 3600.0

    # ---- Subscription (订阅管家) due reminders + auto-record ---------------
    # Background loop that reminds before each subscription's due date and, on
    # the due date, auto-records the charge into accounting (when installed) and
    # rolls the due date forward. Off by default; idempotent per due date.
    subscription_reminder_enabled: bool = False
    subscription_reminder_poll_seconds: float = 3600.0

    # ---- Plant (植物日记) watering / fertilizing reminders -----------------
    # Background loop that reminds when a plant's watering/fertilizing falls due
    # and rolls the next-due date forward by the plant's interval. Off by
    # default; idempotent per due date.
    plant_reminder_enabled: bool = False
    plant_reminder_poll_seconds: float = 3600.0

    # ---- AI (generic LLM access for plugins) ------------------------------
    # A shared module any server-side plugin can call to get model output
    # (see app.services.ai). Provider-agnostic; `ai_provider` selects the
    # backend. Each provider no-ops/raises clearly when its key is blank, so
    # dev/tests run without credentials.
    ai_provider: str = "kimi"
    # LLM calls are slow (K2.5 is a thinking model), so a generous timeout.
    ai_timeout_seconds: float = 60.0
    # Default output cap when a caller doesn't pass one; None = provider default.
    ai_default_max_tokens: int | None = None
    # Kimi / Moonshot — OpenAI-compatible chat-completions API. `kimi-k2.6` is
    # the multimodal (vision) model, required so plugins can send images (e.g.
    # the plant plugin's photo analysis); it also handles text-only calls. Base
    # URL defaults to the China endpoint (the server runs in-region); switch to
    # https://api.moonshot.ai/v1 for the international platform. Blank key → the
    # client raises a clear "not configured" error rather than calling out.
    kimi_api_key: str = ""
    kimi_base_url: str = "https://api.moonshot.cn/v1"
    kimi_model: str = "kimi-k2.6"

    # ---- Weather (generic weather access for plugins) --------------------
    # A shared module any server-side plugin can call for current conditions
    # (see app.services.weather). Provider-agnostic; `weather_provider` selects
    # the backend. Blank key → the client raises a clear "not configured" error.
    weather_provider: str = "qweather"
    weather_timeout_seconds: float = 15.0
    # Weather changes slowly; cache per-location to stay within the provider's
    # free-tier rate limit. TTL in seconds (default 30 min).
    weather_cache_ttl_seconds: float = 1800.0
    # QWeather (和风天气) — REST API keyed by `qweather_api_key`. The base URL
    # MUST include the `/v7` version segment (the client appends `/weather/now`
    # etc. to it). New-console accounts get a per-account **dedicated API Host**
    # (e.g. https://abcd1234.qweatherapi.com) and will 403 "Invalid Host" on the
    # shared devapi host — set `qweather_base_url` to `https://<your-host>/v7`.
    # Old free-tier accounts use the shared devapi host below. A missing `/v7`
    # surfaces as a 404 from `weather/now`.
    qweather_api_key: str = ""
    qweather_base_url: str = "https://devapi.qweather.com/v7"


settings = Settings()
