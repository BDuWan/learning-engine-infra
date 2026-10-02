# Makefile — công cụ vận hành dùng chung cho mọi repo của Personal AI Learning Engine.
# Repo này KHÔNG chứa product code. Cú pháp POSIX: chạy được trên Ubuntu, macOS và Windows (Git Bash).
# Các repo anh em nằm cạnh repo này trong cùng thư mục workspace: ../learning-engine-*.

SHELL := /bin/sh
.DEFAULT_GOAL := help

REPOS := learning-engine-docs learning-engine-backend learning-engine-web learning-engine-infra
PRODUCT_REPOS := learning-engine-backend learning-engine-web
BASE ?= develop
BRANCH ?=
PUSH ?= 1
SKIP_GATE ?= 0
SERVICE ?=
COMPOSE := docker compose

BACKEND_DOCKERFILE := ../learning-engine-backend/Dockerfile
WEB_DOCKERFILE := ../learning-engine-web/Dockerfile
RUNNER_DOCKERFILE := ../learning-engine-backend/build/agent-runner/Dockerfile

.PHONY: help pull merge check-repos env docker-check docker-build docker-up docker-down docker-restart docker-ps docker-logs docker-clean

help: ## Liệt kê các lệnh
	@echo "Lệnh vận hành (chạy trong learning-engine-infra):"
	@echo "  make check-repos            Kiểm 4 repo đã clone cạnh nhau và là git repo"
	@echo "  make pull                   Fast-forward base branch ($(BASE)) ở mọi repo (KHÔNG dùng khi đang review nhánh phase)"
	@echo "  make merge BRANCH=<nhánh>   Merge nhánh phase vào $(BASE) ở mọi repo có nhánh đó, chạy gate rồi push (PUSH=0, SKIP_GATE=1 tuỳ chọn)"
	@echo "  make docker-build           Build image :local từ code đang checkout"
	@echo "  make docker-up              Chạy cả stack local (tự tạo .env từ .env.example nếu chưa có)"
	@echo "  make docker-down            Dừng stack, giữ dữ liệu"
	@echo "  make docker-restart         Build lại và chạy lại stack (dùng khi đổi nhánh để review)"
	@echo "  make docker-ps              Trạng thái các service"
	@echo "  make docker-logs [SERVICE=api]  Xem log"
	@echo "  make docker-clean           Dừng stack và XOÁ volume dữ liệu dev (DB, object storage, vault runner)"

check-repos: ## Kiểm các repo anh em
	@missing=0; for r in $(REPOS); do \
	  if git -C ../$$r rev-parse --git-dir >/dev/null 2>&1; then \
	    printf '  %-26s có mặt (nhánh: %s)\n' "$$r" "$$(git -C ../$$r symbolic-ref --quiet --short HEAD || echo detached)"; \
	  else printf '  %-26s THIẾU — clone vào ../%s (xem learning-engine-docs/docs/23-repository-strategy.md)\n' "$$r" "$$r"; missing=1; fi; \
	done; exit $$missing

pull: check-repos ## Fast-forward base branch ở mọi repo
	@for r in $(REPOS); do \
	  d=../$$r; \
	  if [ -n "$$(git -C $$d status --porcelain)" ]; then echo "  $$r: có thay đổi chưa commit — bỏ qua"; continue; fi; \
	  git -C $$d fetch --quiet origin 2>/dev/null || { echo "  $$r: không fetch được origin (xem docs/29)"; continue; }; \
	  if ! git -C $$d show-ref --verify --quiet refs/remotes/origin/$(BASE); then echo "  $$r: origin chưa có $(BASE) — bỏ qua"; continue; fi; \
	  git -C $$d checkout --quiet $(BASE) 2>/dev/null || git -C $$d checkout --quiet -b $(BASE) origin/$(BASE); \
	  if git -C $$d merge --ff-only --quiet origin/$(BASE); then echo "  $$r: $(BASE) = $$(git -C $$d rev-parse --short HEAD)"; \
	  else echo "  $$r: không fast-forward được $(BASE) — dừng ở repo này, cần người xử lý"; fi; \
	done

merge: ## Merge nhánh phase sau khi người xác nhận (GIT WORKFLOW CONTRACT mục 8)
	@BRANCH="$(BRANCH)" BASE="$(BASE)" PUSH="$(PUSH)" SKIP_GATE="$(SKIP_GATE)" bash scripts/merge-all.sh

env:
	@if [ ! -f .env ]; then cp .env.example .env; echo "  Đã tạo .env từ .env.example (giá trị dev giả)."; fi

docker-check:
	@command -v docker >/dev/null 2>&1 || { echo "Chưa có Docker — cài theo learning-engine-docs/docs/29-environment-setup.md"; exit 1; }
	@ok=1; \
	if [ ! -f $(BACKEND_DOCKERFILE) ]; then echo "  learning-engine-backend: chưa có Dockerfile — tạo ở MAIN-FND-01"; ok=0; fi; \
	if [ ! -f $(WEB_DOCKERFILE) ]; then echo "  learning-engine-web: chưa có Dockerfile — tạo ở MAIN-FND-01"; ok=0; fi; \
	if [ ! -f $(RUNNER_DOCKERFILE) ]; then echo "  agent-runner: chưa có build/agent-runner/Dockerfile — tạo ở MAIN-AIO-01 (stack vẫn chạy, bỏ qua service này)"; fi; \
	if [ $$ok -eq 0 ]; then echo "Stack chưa build được vì product repo chưa có Dockerfile."; exit 1; fi

docker-build: env docker-check ## Build image :local
	@if [ -f $(RUNNER_DOCKERFILE) ]; then $(COMPOSE) --profile ai build; else $(COMPOSE) build; fi

docker-up: env docker-check ## Chạy cả stack
	@if [ -f $(RUNNER_DOCKERFILE) ]; then $(COMPOSE) --profile ai up -d --build; else $(COMPOSE) up -d --build; fi
	@echo "  Web: http://localhost:$${LEARNING_ENGINE_WEB_PORT:-3000}  API readiness: http://localhost:$${LEARNING_ENGINE_API_PORT:-8080}/readyz"

docker-down: ## Dừng stack, giữ volume
	@$(COMPOSE) --profile ai down

docker-restart: docker-down docker-up ## Build lại và chạy lại

docker-ps: ## Trạng thái service
	@$(COMPOSE) --profile ai ps

docker-logs: ## Xem log (SERVICE=api để lọc)
	@$(COMPOSE) --profile ai logs -f --tail=200 $(SERVICE)

docker-clean: ## Dừng stack và xoá volume dev
	@echo "  Xoá dữ liệu dev: postgres-data, garage-data, runner-vault (tài khoản AI đã đăng nhập ở local sẽ mất), runner-work."
	@$(COMPOSE) --profile ai down -v --remove-orphans
