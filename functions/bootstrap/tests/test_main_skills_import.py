"""Regression: ``main`` references ``skills.guided_tour.*`` by qualified
name in ``_chat_context`` (tour fix F2, staging 2318). The plain submodule
import in main.py is what binds the ``skills`` package name there; without
it every /chat and /chat/stream raised ``NameError: name 'skills' is not
defined`` (live on staging from the tour merge until the one-brain staging
proof caught it, 2026-11-06).
"""
import main
import skills.guided_tour


def test_main_binds_skills_package_name():
    assert main.skills.guided_tour is skills.guided_tour
