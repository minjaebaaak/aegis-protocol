# AEGIS Protocol v4.0 Unified Checklist

Dashboard-Independent 통합 검증 프로토콜을 CLI에서 직접 실행합니다.

---
name: AEGIS
description: AEGIS Protocol v4.0 - 웹 대시보드 독립 통합 검증 시스템
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - TodoWrite
  - mcp__sequential-thinking__sequentialthinking
  - mcp__playwright__*
  - mcp__claude-in-chrome__*
---

## 개요

**AEGIS** (Autonomous Enhanced Guard & Inspection System) v4.0은 웹 대시보드 없이 CLI에서 완전한 검증 워크플로우를 실행합니다.

### v4.0 핵심 변경사항

| 구분 | v3.6 (기존) | v4.0 (개선) |
|------|------------|-------------|
| 상태 관리 | WebSocket + Zustand | `.claude/state/aegis.json` |
| 작업 추적 | 칸반 보드 (웹) | TodoWrite + `todos.json` |
| 알림 | 웹 푸시 | Hook 시스템 |
| UI | Next.js 대시보드 | CLI + 이 스킬 |

---

## 사용법

### 기본 명령
```bash
# 세션 초기화
./scripts/aegis-validate.sh --init

# 상태 조회
./scripts/aegis-validate.sh --status

# 체크리스트 실행
./scripts/aegis-validate.sh --pre-commit
./scripts/aegis-validate.sh --pre-deploy
./scripts/aegis-validate.sh --post-deploy

# TodoWrite 동기화
./scripts/aegis-validate.sh --sync-todo

# 리포트 생성
./scripts/aegis-validate.sh --export md
```

### Layer별 검증
```bash
./scripts/aegis-validate.sh --schema <table> <column>  # Layer 0
./scripts/aegis-validate.sh --build                     # Layer 1
./scripts/aegis-validate.sh --api                       # Layer 3
./scripts/aegis-validate.sh --e2e                       # Layer 4 가이드
./scripts/aegis-validate.sh --monitor                   # Layer 6
./scripts/aegis-validate.sh --resource                  # Resource Layer
```

---

## 자동 실행 흐름

### 1. 세션 초기화
```bash
./scripts/aegis-validate.sh --init
```
- `aegis.json` 생성
- 세션 ID 할당
- 모든 Layer pending 상태로 초기화

### 2. TodoWrite 동기화
각 Layer 상태가 자동으로 TodoWrite와 동기화됩니다:
- `pending` → TodoWrite status: "pending"
- `running` → TodoWrite status: "in_progress"
- `pass/fail` → TodoWrite status: "completed"

### 3. Layer별 검증 실행

| Layer | 검증 내용 | 통과 조건 |
|-------|----------|----------|
| 0 | DB 스키마 | 컬럼 존재 |
| 1 | TypeScript 빌드 | exit code 0 |
| 2 | Unit Test | 실패 0개 |
| 3 | API Test | 모든 엔드포인트 200 |
| 4 | E2E (Local) | Playwright 통과 |
| 5 | E2E (Production) | /chrome 검증 통과 |
| 6 | Monitoring | 에러 로그 없음 |
| 7 | Hook Notification | 알림 전송 완료 |

### 4. 결과 리포트
```
╔════════════════════════════════════════════════════════════╗
║  AEGIS v4.0 Dashboard-Independent                          ║
╠════════════════════════════════════════════════════════════╣
║  세션: aegis-1736956800 | 상태: validating                 ║
╠════════════════════════════════════════════════════════════╣
║  ✅ Layer 0: Schema Validation      | pass      | 1200ms   ║
║  ✅ Layer 1: Static Analysis        | pass      | 45000ms  ║
║  ✅ Layer 2: Unit Test              | pass      | 12000ms  ║
║  ✅ Layer 3: Integration Test       | pass      | 8000ms   ║
║  🔄 Layer 4: E2E Test (Local)       | running   | -        ║
║  ⏳ Layer 5: E2E Test (Production)  | pending   | -        ║
║  ⏳ Layer 6: Production Monitoring  | pending   | -        ║
║  ⏳ Layer 7: Hook Notification      | pending   | -        ║
╠════════════════════════════════════════════════════════════╣
║  통과: 4 | 실패: 0 | 진행: 1 | 대기: 3                      ║
╚════════════════════════════════════════════════════════════╝
```

---

## 체크리스트

### Pre-Commit (커밋 전)
- [ ] Layer 0: 새 DB 컬럼 검증 완료
- [ ] Layer 1: pnpm build 성공
- [ ] Layer 2: 관련 테스트 통과

### Pre-Deploy (배포 전)
- [ ] Layer 0-4 모두 통과
- [ ] git push origin master 완료
- [ ] 로컬 API 테스트 완료

### Post-Deploy (배포 후)
- [ ] Layer 6: 에러 로그 없음
- [ ] Layer 5: /chrome으로 프로덕션 검증

---

## 상태 파일 구조

`.claude/state/aegis.json`:
```json
{
  "version": "4.0",
  "session": {
    "id": "aegis-1736956800",
    "phase": "validating",
    "currentLayer": 4
  },
  "layers": {
    "layer0": { "name": "Schema Validation", "status": "pass", "duration": 1200 },
    "layer1": { "name": "Static Analysis", "status": "pass", "duration": 45000 },
    ...
  },
  "metrics": {
    "passedLayers": 4,
    "failedLayers": 0,
    "runningLayers": 1,
    "pendingLayers": 3
  }
}
```

---

## 주의사항

1. **순차 실행**: Layer는 기본적으로 순차 실행됨
2. **실패 시 중단**: `skipOnFail: false`이면 실패 시 중단
3. **타임아웃**: 각 Layer 5분 타임아웃 (설정 변경 가능)
4. **알림**: `autoNotify: true`이면 완료/실패 시 자동 알림
5. **웹 독립**: 웹 대시보드 없이도 모든 기능 동작

---

## 관련 파일

| 파일 | 역할 |
|------|------|
| `.claude/state/aegis.json` | AEGIS 상태 저장 |
| `.claude/state/todos.json` | TodoWrite 동기화 |
| `scripts/aegis-validate.sh` | 검증 스크립트 |
| `.claude/hooks/notify-user.sh` | 알림 훅 |
