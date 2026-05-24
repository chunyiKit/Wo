.PHONY: install dev test lint format db-up db-down db-logs migrate migration

install:
	uv sync

dev:
	uv run uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

test:
	uv run pytest

lint:
	uv run ruff check .

format:
	uv run ruff format .

db-up:
	docker-compose up -d

db-down:
	docker-compose down

db-logs:
	docker-compose logs -f db

migrate:
	uv run alembic upgrade head

migration:
	@if [ -z "$(m)" ]; then echo "Usage: make migration m=\"your message\""; exit 1; fi
	uv run alembic revision --autogenerate -m "$(m)"
