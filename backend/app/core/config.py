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


settings = Settings()
