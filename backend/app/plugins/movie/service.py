"""Movie plugin business logic — just the preview hook for now.

Movies are simple enough that the routes do their own CRUD without a service
layer; only the home-card preview needs a tiny query.
"""

from sqlalchemy import func
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.models.plugin import InstalledPlugin
from app.plugins.movie.models import Movie, MovieRead
from app.plugins.registry import PluginPreview


def build_read(movie: Movie) -> MovieRead:
    """Serialize a movie, injecting the host-relative poster URL (immutable copy).

    The URL is None until the enrichment task saves a poster; `?v=` busts the
    client image cache when a re-enrichment overwrites the same storage key.
    """
    read = MovieRead.model_validate(movie, from_attributes=True)
    poster_url = None
    if movie.poster_storage_key:
        poster_url = (
            f"/api/v1/families/{movie.family_id}/plugins/movie/movies/"
            f"{movie.id}/poster?v={movie.poster_version}"
        )
    return read.model_copy(update={"poster_url": poster_url})


async def preview_hook(
    session: AsyncSession,
    ip: InstalledPlugin,
    viewer_id: object = None,
) -> PluginPreview:
    """Home card: the most-recently-added 「想看」 movie plus how many remain.

    States:
    - 0 总数 → 「还没想看的」 + 「添加一部」副本
    - 0 想看, >0 看过 → 「都看过了」(空想看列表是个小成就)
    - >0 想看 → 显示最新加的片名 + 「还有 N 部想看」副本
    """
    family_id = ip.family_id

    total = int(
        (
            await session.execute(
                select(func.count())
                .select_from(Movie)
                .where(Movie.family_id == family_id)
            )
        ).scalar_one()
    )
    if total == 0:
        return PluginPreview(
            primary="还没想看的",
            secondary="添加一部",
            color_token="movie",
            emoji="🎬",
        )

    want_stmt = (
        select(Movie)
        .where(Movie.family_id == family_id, Movie.watched.is_(False))
        .order_by(Movie.created_at.desc())
    )
    want_rows = list((await session.execute(want_stmt)).scalars().all())

    if not want_rows:
        return PluginPreview(
            primary="都看过了",
            secondary=f"看过 {total} 部",
            color_token="movie",
            emoji="🎬",
        )

    latest = want_rows[0]
    title = latest.title.strip() or "一部电影"
    return PluginPreview(
        primary=title,
        secondary=f"还有 {len(want_rows)} 部想看",
        color_token="movie",
        emoji="🎬",
    )


__all__ = ["preview_hook"]
