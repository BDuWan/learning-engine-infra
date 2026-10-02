# learning-engine-infra — công cụ vận hành của Personal AI Learning Engine

Repo này là **operator tooling**: không chứa product code. Nó giúp chạy cả stack local bằng Docker từ code đang checkout ở các repo anh em, và cung cấp lệnh `make merge` / `make pull` dùng chung cho mọi repo.

Nguồn sự thật về sản phẩm, phase và quy trình: `../learning-engine-docs` (đọc `learning-engine-docs/AGENTS.md` trước).

## Bố cục workspace

Mọi repo được clone cạnh nhau trong cùng một thư mục:

```
<workspace>/
├── AGENTS.md                  (chỉ đường cho coding agent mở ở gốc workspace)
├── learning-engine-docs       (blueprint — tài liệu)
├── learning-engine-backend    (Go: api, worker, agent-runner, migrate)
├── learning-engine-web        (Next.js)
└── learning-engine-infra      (repo này)
```

## Bảng lệnh

| Lệnh | Tác dụng |
|---|---|
| `make help` | Liệt kê lệnh |
| `make check-repos` | Kiểm 4 repo đã clone cạnh nhau; báo đúng tên repo còn thiếu |
| `make pull` | Fast-forward `develop` ở mọi repo (không dùng khi đang review nhánh phase vì nó đưa repo về `develop`) |
| `make merge BRANCH=phase/<PHASE-ID>-<slug>` | Merge nhánh phase vào `develop` ở mọi repo có nhánh đó, chỉ sau khi người review xác nhận |
| `make docker-build` | Build image `learning-engine-backend:local`, `learning-engine-web:local`, `learning-engine-agent-runner:local` |
| `make docker-up` | Chạy cả stack (tự tạo `.env` từ `.env.example` nếu chưa có) |
| `make docker-down` | Dừng stack, giữ dữ liệu |
| `make docker-restart` | Build lại và chạy lại (dùng sau khi đổi nhánh) |
| `make docker-ps` | Trạng thái service |
| `make docker-logs SERVICE=api` | Xem log một service (bỏ SERVICE để xem tất cả) |
| `make docker-clean` | Dừng stack và xoá volume dev (DB, object storage, vault của agent-runner) |

## Stack local

| Service | Image | Cổng host | Ghi chú |
|---|---|---|---|
| `postgres` | `postgres:18.6` | 5432 | DB `learning_engine_dev`, role `learning_engine_owner` (migration) và `learning_engine_app` (runtime, tạo bởi `initdb/01-app-role.sh`) |
| `garage` | `dxflrs/garage:v2.4.1` | 3900 | Object storage S3-compatible một node; bucket `learning-engine-content` tự tạo |
| `migrate` | `learning-engine-backend:local` | — | Chạy `/app/migrate up` rồi thoát |
| `api` | `learning-engine-backend:local` | 8080 | `/healthz`, `/readyz`, `/api/v1/...` |
| `worker` | `learning-engine-backend:local` | — | River worker (không chạy AI CLI) |
| `agent-runner` | `learning-engine-agent-runner:local` | — | Profile `ai`; chạy agent CLI subscription; volume `runner-vault`, `runner-work`; không mount Docker socket |
| `web` | `learning-engine-web:local` | 3000 | Giao diện vi/en, sáng/tối |

- Lúc gen blueprint (2026-10-03) product repo chưa có Dockerfile: `make docker-up` sẽ báo "chưa có Dockerfile — tạo ở MAIN-FND-01".
- `build/agent-runner/Dockerfile` do MAIN-AIO-01 tạo; trước đó stack vẫn chạy, chỉ bỏ qua service `agent-runner`.
- Ở dev, `LEARNING_ENGINE_RUNNER_FAKE_ADAPTER=true` cho phép chạy AI task mà không cần tài khoản subscription.

## Review một phase trên local (code của nhánh phase)

1. Ở từng repo có nhánh phase: `git fetch`, `git checkout phase/<PHASE-ID>-<slug>`, `git pull --ff-only`; repo không có nhánh thì để ở `develop`.
2. Đối chiếu commit cuối với "ghi chú bàn giao nhánh" trong phase log.
3. Trong repo này: `make docker-restart`, rồi mở http://localhost:3000 và kiểm http://localhost:8080/readyz.
4. Chuyển về nhánh cũ hơn sau khi DB đã chạy migration mới: `make docker-clean` rồi `make docker-up`.
5. Xem DB dev: `docker compose exec postgres psql -U learning_engine_owner learning_engine_dev`.
6. Khi phase đạt: nói rõ với agent "<PHASE-ID> done, merge đi".

## `make merge` làm gì

- Thứ tự repo: `learning-engine-backend` → `learning-engine-web` → `learning-engine-docs` → `learning-engine-infra`.
- Preflight: repo sạch, `git fetch`, fast-forward `develop` cục bộ; không fast-forward được thì dừng.
- Kiểm conflict ở mọi repo bằng `git merge-tree` trước khi merge repo nào; có conflict thì dừng, in repo + file, không repo nào bị merge.
- Merge `--no-ff` với message `Merge <nhánh> into develop [<PHASE-ID>]`, rồi chạy gate thực có của từng repo.
- Gate từng repo: backend `make lint test build migrate-validate`; web `pnpm install --frozen-lockfile` rồi `pnpm lint`, `pnpm typecheck`, `pnpm test`, `pnpm build`; docs parse JSON `phase-data` của `phase-tracking.html`; infra `docker compose config` + `bash -n`.
- Gate lỗi ở bất kỳ repo nào: không push repo nào, trả `develop` cục bộ về trạng thái trước merge.
- Gate đạt: `git push origin develop` (không `--force`), trả mỗi repo về nhánh đang đứng lúc đầu; không xoá nhánh, không đụng `main`.
- `PUSH=0` (không push) và `SKIP_GATE=1` chỉ dùng khi người dùng yêu cầu rõ.

## Quy tắc ghi vào repo này

- Phase thường không ghi vào repo này; MAIN-FND-01 và MAIN-AIO-01 được sửa `docker-compose.yml` và `.env.example` theo append-block (khối có comment Phase ID).
- Không commit `.env`; không commit ảnh/video.
- Hướng dẫn cài Docker, Make, Git Bash: `../learning-engine-docs/docs/29-environment-setup.md`.
