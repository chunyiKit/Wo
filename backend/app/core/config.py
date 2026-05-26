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

    # Login throttling within the window (seconds). Per-IP guards against
    # enumeration/bulk registration; per-phone guards a single number against
    # targeting (and SMS bombing once P5 adds codes).
    login_rate_limit_max: int = 10
    login_rate_limit_per_phone_max: int = 5
    login_rate_limit_window_seconds: int = 60

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


settings = Settings()
