"""Prefix-based route modules for Ayma Main API."""

from routes.appearance import router as appearance_router
from routes.cron import router as cron_router
from routes.media import router as media_router
from routes.profile import router as profile_router
from routes.story import router as story_router

__all__ = [
    "appearance_router",
    "cron_router",
    "media_router",
    "profile_router",
    "story_router",
]
