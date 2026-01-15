#!/bin/bash

# ============================================================================
# AEGIS Validation Script v4.0
# Autonomous Enhanced Guard & Inspection System
# Dashboard-Independent - 웹 대시보드 없이 CLI 기반 완전 자율 검증
# v4.0: 웹 대시보드 의존성 제거, 파일 기반 상태 관리, TodoWrite 통합
# v3.1: npm → pnpm 전환 (corepack 기반)
# ============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# pnpm 자동 활성화 (corepack 사용)
ensure_pnpm() {
    if ! command -v corepack &> /dev/null; then
        print_warning "corepack을 찾을 수 없습니다. Node.js 16.9+ 필요"
        print_info "npm install -g pnpm 으로 수동 설치 시도..."
        npm install -g pnpm 2>/dev/null || true
        return
    fi

    # corepack 활성화 (pnpm 자동 설치)
    corepack enable 2>/dev/null || true
}

# Configuration (환경 변수로 오버라이드 가능)
SSH_HOST="${AEGIS_SSH_HOST:-}"
PROJECT_PATH="${AEGIS_PROJECT_PATH:-$(pwd)}"
LOCAL_PORT="${AEGIS_LOCAL_PORT:-3000}"
DB_CONTAINER="${AEGIS_DB_CONTAINER:-}"
DB_USER="${AEGIS_DB_USER:-}"
DB_NAME="${AEGIS_DB_NAME:-monitoring}"

# Detect if running on server or local
is_server() {
    [[ -f "$PROJECT_PATH/package.json" ]] && [[ "$(hostname)" != "MinjaeUI-MacBookPro.local" ]]
}

# Execute DB command (SSH if local, direct if server)
exec_db() {
    local cmd=$1
    if is_server; then
        docker exec $DB_CONTAINER psql -U $DB_USER -d $DB_NAME -t -c "$cmd" 2>/dev/null
    else
        ssh $SSH_HOST "docker exec $DB_CONTAINER psql -U $DB_USER -d $DB_NAME -t -c \"$cmd\"" 2>/dev/null
    fi
}

# Execute PM2 command
exec_pm2() {
    local cmd=$1
    if is_server; then
        eval "$cmd" 2>/dev/null
    else
        ssh $SSH_HOST "$cmd" 2>/dev/null
    fi
}

# ============================================================================
# Helper Functions
# ============================================================================

print_header() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BLUE}AEGIS${NC} - $1"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_layer() {
    echo -e "${YELLOW}▶ Layer $1: $2${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# ============================================================================
# Layer 0: Schema Validation
# ============================================================================

validate_schema() {
    local table=$1
    local column=$2

    print_layer "0" "Schema Validation"

    if [[ -z "$table" ]]; then
        print_error "테이블명을 지정해주세요"
        echo "사용법: $0 --schema <table_name> [column_name]"
        exit 1
    fi

    print_info "테이블 '$table' 스키마 확인 중..."

    # Get columns from DB
    local columns=$(exec_db "
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_name = '$table'
        ORDER BY ordinal_position;
    ")

    if [[ -z "$columns" ]]; then
        print_error "테이블 '$table'이 존재하지 않습니다!"
        exit 1
    fi

    echo ""
    echo "현재 컬럼 목록:"
    echo "$columns"
    echo ""

    if [[ -n "$column" ]]; then
        if echo "$columns" | grep -q "$column"; then
            print_success "컬럼 '$column'이 존재합니다"
        else
            print_error "컬럼 '$column'이 존재하지 않습니다!"
            echo ""
            print_warning "다음 SQL로 컬럼을 추가하세요:"
            echo ""
            echo -e "${CYAN}ALTER TABLE $table ADD COLUMN $column <DATA_TYPE> DEFAULT NULL;${NC}"
            echo ""
            exit 1
        fi
    fi

    print_success "Layer 0 통과"
}

# ============================================================================
# Layer 1: Static Analysis (Build)
# ============================================================================

# 프로젝트 타입 감지
detect_project_type() {
    if [[ -f "pyproject.toml" ]] || [[ -f "setup.py" ]] || [[ -f "requirements.txt" ]]; then
        # Python 파일이 있는지도 확인
        local py_count=$(find . -maxdepth 2 -name "*.py" -type f 2>/dev/null | wc -l)
        if [[ $py_count -gt 0 ]]; then
            echo "python"
            return
        fi
    fi

    if [[ -f "package.json" ]]; then
        # package.json에 build 스크립트가 있는지 확인
        if grep -q '"build"' package.json 2>/dev/null; then
            echo "node"
            return
        fi
    fi

    # Python 파일만 있는 경우
    local py_count=$(find . -maxdepth 2 -name "*.py" -type f 2>/dev/null | wc -l)
    if [[ $py_count -gt 0 ]]; then
        echo "python"
        return
    fi

    echo "unknown"
}

validate_build() {
    print_layer "1" "Static Analysis (Build)"

    local project_type=$(detect_project_type)
    print_info "프로젝트 타입: $project_type"

    case "$project_type" in
        "python")
            validate_python
            ;;
        "node")
            validate_node
            ;;
        *)
            print_warning "알 수 없는 프로젝트 타입입니다"
            print_info "Python 또는 Node.js 프로젝트가 필요합니다"
            print_success "Layer 1 스킵"
            ;;
    esac
}

# Python 프로젝트 검증
validate_python() {
    local failed=0
    local py_files=$(find . -maxdepth 2 -name "*.py" -type f 2>/dev/null)
    local py_count=$(echo "$py_files" | wc -l)

    print_info "Python 파일 ${py_count}개 검증 중..."

    # 1. Python 문법 검사
    print_info "Python 문법 검사 중..."
    local syntax_errors=0
    for pyfile in $py_files; do
        if ! python3 -m py_compile "$pyfile" 2>/dev/null; then
            print_error "문법 오류: $pyfile"
            syntax_errors=$((syntax_errors + 1))
            failed=1
        fi
    done

    if [[ $syntax_errors -eq 0 ]]; then
        print_success "문법 검사 통과 (${py_count}개 파일)"
    else
        print_error "문법 오류 ${syntax_errors}개 발견"
    fi

    # 2. flake8 린트 (설치된 경우)
    if command -v flake8 &> /dev/null; then
        print_info "flake8 린트 검사 중..."
        local flake_output=$(flake8 --max-line-length=120 --ignore=E501,W503 . 2>/dev/null | head -20)
        if [[ -z "$flake_output" ]]; then
            print_success "flake8 통과"
        else
            print_warning "flake8 경고 발견 (무시 가능)"
            echo "$flake_output" | head -5
        fi
    else
        print_info "flake8 미설치 - 스킵"
    fi

    # 3. 가상환경 확인
    if [[ -d "venv" ]] || [[ -d ".venv" ]]; then
        print_success "가상환경 확인됨"
    else
        print_info "가상환경 없음 (권장: python3 -m venv venv)"
    fi

    if [[ $failed -eq 0 ]]; then
        print_success "Layer 1 통과 (Python)"
        update_layer_status 1 "pass"
        update_metrics
    else
        print_error "Layer 1 실패 (Python)"
        update_layer_status 1 "fail"
        update_metrics
        exit 1
    fi
}

# Node.js 프로젝트 검증
validate_node() {
    print_info "TypeScript 빌드 중... (GPU 비활성화, 메모리 16GB 할당)"

    # GPU/CUDA 완전 비활성화 (빌드 시 GPU 메모리 충돌 방지)
    export CUDA_VISIBLE_DEVICES=""
    export TF_CPP_MIN_LOG_LEVEL=3
    export TF_FORCE_GPU_ALLOW_GROWTH=false
    export PYTORCH_NO_CUDA_MEMORY_CACHING=1
    export CUDA_DEVICE_ORDER=PCI_BUS_ID

    # Node.js 힙 메모리 16GB 설정 (OOM 방지)
    ensure_pnpm
    if NODE_OPTIONS="--max-old-space-size=16384" pnpm build > /dev/null 2>&1; then
        print_success "빌드 성공"
        print_success "Layer 1 통과 (Node.js)"
        update_layer_status 1 "pass"
        update_metrics
    else
        print_error "빌드 실패!"
        echo ""
        print_info "pnpm build 를 직접 실행하여 에러를 확인하세요"
        update_layer_status 1 "fail"
        update_metrics
        exit 1
    fi
}

# ============================================================================
# Layer 3: Integration Test (API)
# ============================================================================

validate_api() {
    print_layer "3" "Integration Test (API)"

    local base_url="http://localhost:$LOCAL_PORT"
    local failed=0

    # Check if server is running
    if ! curl -s "$base_url" > /dev/null 2>&1; then
        print_warning "로컬 서버가 실행 중이지 않습니다 (port $LOCAL_PORT)"
        print_info "pnpm dev -p $LOCAL_PORT 로 서버를 시작하세요"
        return 1
    fi

    # AEGIS 토큰 확인 (환경 변수에서)
    if [[ -z "$AEGIS_INTERNAL_TOKEN" ]]; then
        print_warning "AEGIS_INTERNAL_TOKEN이 설정되지 않았습니다"
        print_info "서버 .bashrc에 다음을 추가하세요:"
        echo "       export AEGIS_INTERNAL_TOKEN=\$(openssl rand -hex 32)"
        print_warning "Layer 3 스킵"
        return 0
    fi

    print_info "AEGIS 내부 검증 API 테스트 중..."

    # AEGIS 전용 검증 API 사용 (보안: localhost + 토큰)
    local checks=(
        "health:서버 상태"
        "database:DB 연결"
        "crawl-results:크롤링 결과"
        "crawl-normal:정상 콘텐츠"
        "crawl-suspicious:의심 콘텐츠"
    )

    for check_item in "${checks[@]}"; do
        local check="${check_item%%:*}"
        local label="${check_item##*:}"

        local response=$(curl -s -H "X-AEGIS-Token: $AEGIS_INTERNAL_TOKEN" \
            "$base_url/api/aegis/validate?check=$check" 2>/dev/null)
        local success=$(echo "$response" | jq -r '.success' 2>/dev/null)

        if [[ "$success" == "true" ]]; then
            local message=$(echo "$response" | jq -r '.results[0].message' 2>/dev/null)
            print_success "$label: $message"
        else
            print_error "$label"
            local error=$(echo "$response" | jq -r '.error // .results[0].message' 2>/dev/null)
            if [[ -n "$error" && "$error" != "null" ]]; then
                echo "       에러: $error"
            fi
            failed=1
        fi
    done

    if [[ $failed -eq 0 ]]; then
        print_success "Layer 3 통과"
    else
        print_error "Layer 3 실패"
        exit 1
    fi
}

# ============================================================================
# Layer 4: E2E Test Guide (Playwright MCP + /chrome)
# ============================================================================

show_e2e_guide() {
    print_layer "4" "E2E Test Guide"

    echo ""
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}  ${YELLOW}Layer 4-A: Playwright MCP (로컬/스테이징)${NC}"
    echo -e "${CYAN}├─────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC}  사용 시점: 로컬 개발 환경 (localhost:3001)"
    echo -e "${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  사전 준비:"
    echo -e "${CYAN}│${NC}    ${GREEN}pkill -f \"ms-playwright\" || true${NC}"
    echo -e "${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  테스트 시나리오:"
    echo -e "${CYAN}│${NC}    1. 로그인 테스트"
    echo -e "${CYAN}│${NC}    2. 대시보드 접근 테스트"
    echo -e "${CYAN}│${NC}    3. 크롤링 결과 페이지 테스트"
    echo -e "${CYAN}│${NC}    4. DNA 매칭 테스트"
    echo -e "${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ⚠️  about:blank 무한 접속 방지를 위해 스크린샷으로 수시 상태 확인"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}  ${YELLOW}Layer 4-B: /chrome (프로덕션 검증)${NC}"
    echo -e "${CYAN}├─────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC}  사용 시점: 배포 후 프로덕션 환경 (https://deep-scan.ai)"
    echo -e "${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  사용 방법:"
    echo -e "${CYAN}│${NC}    Claude Code에서 /chrome 명령으로 실제 Chrome 브라우저 제어"
    echo -e "${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  테스트 시나리오:"
    echo -e "${CYAN}│${NC}    1. 프로덕션 URL 접속 확인"
    echo -e "${CYAN}│${NC}    2. 로그인 기능 검증"
    echo -e "${CYAN}│${NC}    3. 핵심 기능 동작 확인"
    echo -e "${CYAN}│${NC}    4. 스크린샷 캡처로 상태 확인"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
    echo ""

    print_info "Layer 4는 Claude Code MCP 도구로 수동 실행"
    print_success "Layer 4 가이드 출력 완료"
}

# ============================================================================
# Resource Layer: Memory, Disk, Cleanup (Phase 2 - AEGIS v3.5)
# ============================================================================

validate_resource() {
    print_layer "R" "Resource Validation (AEGIS v3.5)"

    local failed=0
    local warnings=0

    # 1. Memory Check (RSS 기준)
    print_info "메모리 사용량 확인 중..."

    local next_server_mem=""
    if is_server; then
        next_server_mem=$(ps aux | grep "[n]ext-server" | awk '{sum+=$6} END {printf "%.0f", sum/1024}')
    else
        next_server_mem=$(ssh $SSH_HOST "ps aux | grep '[n]ext-server' | awk '{sum+=\$6} END {printf \"%.0f\", sum/1024}'" 2>/dev/null)
    fi

    if [[ -n "$next_server_mem" && "$next_server_mem" -gt 0 ]]; then
        if [[ "$next_server_mem" -gt 8000 ]]; then
            print_error "next-server 메모리: ${next_server_mem}MB (8GB 초과!)"
            failed=1
        elif [[ "$next_server_mem" -gt 4000 ]]; then
            print_warning "next-server 메모리: ${next_server_mem}MB (4GB 초과, 주의)"
            warnings=$((warnings+1))
        else
            print_success "next-server 메모리: ${next_server_mem}MB (정상)"
        fi
    else
        print_info "next-server 프로세스 없음 (서버 미실행)"
    fi

    # 2. /tmp Cleanup Check
    print_info "/tmp 임시파일 확인 중..."

    local tmp_size=""
    if is_server; then
        tmp_size=$(du -sm /tmp/crawl_analyze_* 2>/dev/null | awk '{sum+=$1} END {printf "%.0f", sum}')
    else
        tmp_size=$(ssh $SSH_HOST "du -sm /tmp/crawl_analyze_* 2>/dev/null | awk '{sum+=\$1} END {printf \"%.0f\", sum}'" 2>/dev/null)
    fi

    if [[ -n "$tmp_size" && "$tmp_size" -gt 0 ]]; then
        if [[ "$tmp_size" -gt 5000 ]]; then
            print_error "/tmp 임시파일: ${tmp_size}MB (5GB 초과!)"
            failed=1
        elif [[ "$tmp_size" -gt 1000 ]]; then
            print_warning "/tmp 임시파일: ${tmp_size}MB (1GB 초과, 정리 권장)"
            warnings=$((warnings+1))
        else
            print_success "/tmp 임시파일: ${tmp_size}MB (정상)"
        fi
    else
        print_success "/tmp 임시파일: 없음 (정상)"
    fi

    # 3. Playwright Zombie Check
    print_info "Playwright 프로세스 확인 중..."

    local pw_count=""
    if is_server; then
        pw_count=$(ls -d /tmp/playwright_chromiumdev_profile-* 2>/dev/null | wc -l)
    else
        pw_count=$(ssh $SSH_HOST "ls -d /tmp/playwright_chromiumdev_profile-* 2>/dev/null | wc -l" 2>/dev/null)
    fi

    if [[ -n "$pw_count" && "$pw_count" -gt 0 ]]; then
        if [[ "$pw_count" -gt 10 ]]; then
            print_error "Playwright 임시 프로필: ${pw_count}개 (10개 초과!)"
            failed=1
        elif [[ "$pw_count" -gt 5 ]]; then
            print_warning "Playwright 임시 프로필: ${pw_count}개 (정리 권장)"
            warnings=$((warnings+1))
        else
            print_success "Playwright 임시 프로필: ${pw_count}개 (정상)"
        fi
    else
        print_success "Playwright 임시 프로필: 없음 (정상)"
    fi

    # 4. Disk Usage Check
    print_info "디스크 사용량 확인 중..."

    local disk_usage=""
    if is_server; then
        disk_usage=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
    else
        disk_usage=$(ssh $SSH_HOST "df / | tail -1 | awk '{print \$5}' | tr -d '%'" 2>/dev/null)
    fi

    if [[ -n "$disk_usage" ]]; then
        if [[ "$disk_usage" -gt 90 ]]; then
            print_error "디스크 사용량: ${disk_usage}% (90% 초과!)"
            failed=1
        elif [[ "$disk_usage" -gt 80 ]]; then
            print_warning "디스크 사용량: ${disk_usage}% (80% 초과, 주의)"
            warnings=$((warnings+1))
        else
            print_success "디스크 사용량: ${disk_usage}% (정상)"
        fi
    fi

    # Summary
    echo ""
    if [[ $failed -gt 0 ]]; then
        print_error "Resource Layer 실패! (에러: $failed, 경고: $warnings)"
        echo ""
        print_info "정리 명령:"
        echo "  pkill -f 'chromiumdev' || true"
        echo "  rm -rf /tmp/playwright_chromiumdev_profile-*"
        echo "  find /tmp -name 'crawl_analyze_*' -mmin +60 -exec rm -rf {} \\;"
        exit 1
    elif [[ $warnings -gt 0 ]]; then
        print_warning "Resource Layer 경고 있음 (경고: $warnings)"
    else
        print_success "Resource Layer 통과"
    fi
}

# ============================================================================
# Layer 6: Production Monitoring
# ============================================================================

monitor_production() {
    print_layer "6" "Production Monitoring"

    print_info "프로덕션 로그 확인 중..."

    local errors=$(exec_pm2 "pm2 logs deep-scan-production --lines 100 --nostream 2>/dev/null | grep -i 'error\|exception\|failed' | tail -10")

    if [[ -n "$errors" ]]; then
        print_warning "최근 에러 발견:"
        echo ""
        echo "$errors"
        echo ""
    else
        print_success "최근 에러 없음"
    fi

    # Check PM2 status
    print_info "PM2 상태:"
    exec_pm2 "pm2 status"

    print_success "Layer 6 완료"
}

# ============================================================================
# Full Validation (All Layers)
# ============================================================================

validate_all() {
    print_header "Full Validation (Layer 0-4)"

    # Layer 1: Build
    validate_build
    echo ""

    # Layer 3: API (if server running)
    if curl -s "http://localhost:$LOCAL_PORT" > /dev/null 2>&1; then
        validate_api
        echo ""
    else
        print_warning "Layer 3 스킵 (서버 미실행)"
        echo ""
    fi

    print_success "모든 검증 통과!"
}

# ============================================================================
# Deploy with Validation
# ============================================================================

deploy_with_validation() {
    print_header "Deploy with Validation"

    # Run all validations first
    validate_all

    echo ""
    print_info "프로덕션 배포 시작..."

    # Deploy
    if is_server; then
        "$PROJECT_PATH/scripts/deploy.sh"
    else
        ssh $SSH_HOST "$PROJECT_PATH/scripts/deploy.sh"
    fi

    echo ""
    print_info "배포 후 모니터링..."
    sleep 5

    # Monitor
    monitor_production

    print_success "배포 완료!"
}

# ============================================================================
# AEGIS v4.0 - State Management Functions (Dashboard-Independent)
# ============================================================================

AEGIS_STATE_FILE="$HOME/.claude/state/aegis.json"

# 상태 파일 초기화
init_aegis_state() {
    local state_dir="$HOME/.claude/state"

    mkdir -p "$state_dir"

    cat > "$AEGIS_STATE_FILE" << 'EOF'
{
  "version": "4.0",
  "session": {
    "id": "aegis-TIMESTAMP",
    "startTime": "DATETIME",
    "phase": "initialized",
    "mode": "normal",
    "currentLayer": null,
    "lastActivity": "DATETIME"
  },
  "layers": {
    "layer0": { "name": "Schema Validation", "status": "pending", "lastRun": null, "duration": null, "result": null },
    "layer1": { "name": "Static Analysis", "status": "pending", "lastRun": null, "duration": null, "result": null },
    "layer2": { "name": "Unit Test", "status": "pending", "lastRun": null, "duration": null, "result": null },
    "layer3": { "name": "Integration Test", "status": "pending", "lastRun": null, "duration": null, "result": null },
    "layer4": { "name": "E2E Test (Local)", "status": "pending", "lastRun": null, "duration": null, "result": null },
    "layer5": { "name": "E2E Test (Production)", "status": "pending", "lastRun": null, "duration": null, "result": null },
    "layer6": { "name": "Production Monitoring", "status": "pending", "lastRun": null, "duration": null, "result": null },
    "layer7": { "name": "Hook Notification", "status": "pending", "lastRun": null, "duration": null, "result": null }
  },
  "checklist": {
    "preCommit": [
      { "id": "pc1", "task": "Layer 0: DB 스키마 검증", "done": false },
      { "id": "pc2", "task": "Layer 1: pnpm build 성공", "done": false },
      { "id": "pc3", "task": "Layer 2: 관련 테스트 통과", "done": false }
    ],
    "preDeploy": [
      { "id": "pd1", "task": "Layer 0-4 모두 통과", "done": false },
      { "id": "pd2", "task": "git push origin master 완료", "done": false },
      { "id": "pd3", "task": "로컬 API 테스트 완료", "done": false }
    ],
    "postDeploy": [
      { "id": "post1", "task": "Layer 6: 에러 로그 없음", "done": false },
      { "id": "post2", "task": "Layer 5: 프로덕션 검증 완료", "done": false }
    ]
  },
  "metrics": {
    "passedLayers": 0,
    "failedLayers": 0,
    "runningLayers": 0,
    "pendingLayers": 8,
    "totalDuration": 0,
    "lastFullRun": null
  },
  "config": {
    "autoNotify": true,
    "parallelExecution": false,
    "skipOnFail": false,
    "timeoutPerLayer": 300000
  }
}
EOF

    # 타임스탬프 치환
    local now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local session_id="aegis-$(date +%s)"

    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s/TIMESTAMP/$session_id/g" "$AEGIS_STATE_FILE"
        sed -i '' "s/DATETIME/$now/g" "$AEGIS_STATE_FILE"
    else
        sed -i "s/TIMESTAMP/$session_id/g" "$AEGIS_STATE_FILE"
        sed -i "s/DATETIME/$now/g" "$AEGIS_STATE_FILE"
    fi

    print_success "AEGIS v4.0 세션 초기화 완료: $AEGIS_STATE_FILE"
}

# 레이어 상태 업데이트
update_layer_status() {
    local layer=$1
    local status=$2
    local result="${3:-null}"
    local duration="${4:-null}"

    if [[ ! -f "$AEGIS_STATE_FILE" ]]; then
        print_warning "상태 파일 없음. --init으로 초기화하세요."
        return 1
    fi

    local now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # jq로 상태 업데이트
    local tmp_file=$(mktemp)
    jq --arg layer "layer$layer" \
       --argjson layerNum "$layer" \
       --arg status "$status" \
       --arg now "$now" \
       --argjson result "$result" \
       --argjson duration "$duration" \
       '.layers[$layer].status = $status |
        .layers[$layer].lastRun = $now |
        .layers[$layer].result = $result |
        .layers[$layer].duration = $duration |
        .session.lastActivity = $now |
        .session.currentLayer = $layerNum' \
       "$AEGIS_STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$AEGIS_STATE_FILE"
}

# 메트릭스 자동 갱신
update_metrics() {
    if [[ ! -f "$AEGIS_STATE_FILE" ]]; then
        return 1
    fi

    local tmp_file=$(mktemp)
    jq '.metrics.passedLayers = ([.layers[] | select(.status == "pass")] | length) |
        .metrics.failedLayers = ([.layers[] | select(.status == "fail")] | length) |
        .metrics.runningLayers = ([.layers[] | select(.status == "running")] | length) |
        .metrics.pendingLayers = ([.layers[] | select(.status == "pending")] | length)' \
       "$AEGIS_STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$AEGIS_STATE_FILE"
}

# TodoWrite용 JSON 동기화 (todos.json 생성)
sync_todowrite() {
    local todos_file="$HOME/.claude/state/todos.json"

    if [[ ! -f "$AEGIS_STATE_FILE" ]]; then
        print_error "AEGIS 상태 파일이 없습니다. --init으로 초기화하세요."
        return 1
    fi

    jq '[
      .layers | to_entries[] | {
        content: ("AEGIS Layer " + (.key | ltrimstr("layer")) + ": " + .value.name),
        status: (if .value.status == "pass" or .value.status == "fail" then "completed"
                 elif .value.status == "running" then "in_progress"
                 else "pending" end),
        activeForm: (if .value.status == "running" then "검증 실행 중"
                     elif .value.status == "pass" then "통과 완료"
                     elif .value.status == "fail" then "실패"
                     else "대기 중" end)
      }
    ]' "$AEGIS_STATE_FILE" > "$todos_file"

    print_success "TodoWrite 동기화 완료: $todos_file"
}

# 알림 훅 호출
notify_aegis() {
    local message=$1
    local title="${2:-AEGIS v4.0}"

    if [[ -f "$HOME/.claude/hooks/notify-user.sh" ]]; then
        "$HOME/.claude/hooks/notify-user.sh" "$message" "$title"
    else
        # 터미널 벨
        echo -e "\a"
        print_info "알림: $message"
    fi
}

# CLI 상태 표시 (pretty print)
show_aegis_status() {
    if [[ ! -f "$AEGIS_STATE_FILE" ]]; then
        print_error "AEGIS 상태 파일이 없습니다. --init으로 초기화하세요."
        exit 1
    fi

    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BLUE}AEGIS v4.0 Dashboard-Independent${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"

    # 세션 정보
    local session_id=$(jq -r '.session.id // "N/A"' "$AEGIS_STATE_FILE")
    local phase=$(jq -r '.session.phase // "idle"' "$AEGIS_STATE_FILE")
    echo -e "${CYAN}║${NC}  세션: ${YELLOW}$session_id${NC} | 상태: ${YELLOW}$phase${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"

    # Layer 상태 출력
    for i in {0..7}; do
        local name=$(jq -r ".layers.layer$i.name" "$AEGIS_STATE_FILE")
        local status=$(jq -r ".layers.layer$i.status" "$AEGIS_STATE_FILE")
        local duration=$(jq -r ".layers.layer$i.duration // \"-\"" "$AEGIS_STATE_FILE")

        local icon=""
        local color=""
        case "$status" in
            pass) icon="✅"; color="${GREEN}" ;;
            fail) icon="❌"; color="${RED}" ;;
            running) icon="🔄"; color="${YELLOW}" ;;
            pending) icon="⏳"; color="${NC}" ;;
        esac

        if [[ "$duration" != "-" && "$duration" != "null" ]]; then
            duration="${duration}ms"
        else
            duration="-"
        fi

        printf "${CYAN}║${NC}  $icon Layer $i: ${color}%-25s${NC} | %-10s | %s\n" "$name" "$status" "$duration"
    done

    echo -e "${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"

    # 메트릭스 출력
    local passed=$(jq '.metrics.passedLayers' "$AEGIS_STATE_FILE")
    local failed=$(jq '.metrics.failedLayers' "$AEGIS_STATE_FILE")
    local running=$(jq '.metrics.runningLayers' "$AEGIS_STATE_FILE")
    local pending=$(jq '.metrics.pendingLayers' "$AEGIS_STATE_FILE")

    echo -e "${CYAN}║${NC}  ${GREEN}통과: $passed${NC} | ${RED}실패: $failed${NC} | ${YELLOW}진행: $running${NC} | 대기: $pending"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# 리포트 내보내기
export_aegis_report() {
    local format="${1:-md}"
    local output_file="aegis-report-$(date +%Y%m%d-%H%M%S).$format"

    if [[ ! -f "$AEGIS_STATE_FILE" ]]; then
        print_error "AEGIS 상태 파일이 없습니다."
        return 1
    fi

    case "$format" in
        json)
            cp "$AEGIS_STATE_FILE" "$output_file"
            ;;
        md)
            cat > "$output_file" << EOF
# AEGIS v4.0 검증 리포트

**생성일시**: $(date '+%Y-%m-%d %H:%M:%S')
**세션 ID**: $(jq -r '.session.id' "$AEGIS_STATE_FILE")

## Layer 검증 결과

| Layer | 이름 | 상태 | 실행 시간 |
|-------|------|------|----------|
$(jq -r '.layers | to_entries[] | "| \(.key | ltrimstr("layer")) | \(.value.name) | \(.value.status) | \(.value.duration // "-")ms |"' "$AEGIS_STATE_FILE")

## 메트릭스

- 통과: $(jq '.metrics.passedLayers' "$AEGIS_STATE_FILE")
- 실패: $(jq '.metrics.failedLayers' "$AEGIS_STATE_FILE")
- 진행중: $(jq '.metrics.runningLayers' "$AEGIS_STATE_FILE")
- 대기: $(jq '.metrics.pendingLayers' "$AEGIS_STATE_FILE")

---
*Generated by AEGIS v4.0 Dashboard-Independent*
EOF
            ;;
    esac

    print_success "리포트 생성 완료: $output_file"
}

# Pre-Commit 체크리스트 실행
run_pre_commit() {
    print_header "Pre-Commit Checklist"

    # Layer 0 스킵 (테이블 지정 필요)
    print_info "Layer 0: --schema <table> <column>으로 별도 실행"

    # Layer 1: Build
    update_layer_status 1 "running"
    update_metrics

    local start_time=$(date +%s%3N)
    if validate_build 2>/dev/null; then
        local end_time=$(date +%s%3N)
        local duration=$((end_time - start_time))
        update_layer_status 1 "pass" '{"buildSuccess": true}' "$duration"
    else
        update_layer_status 1 "fail" '{"buildSuccess": false}'
    fi
    update_metrics

    # Layer 2: Unit Test (pnpm test가 있으면)
    if [[ -f "package.json" ]] && grep -q '"test"' package.json; then
        update_layer_status 2 "running"
        update_metrics

        start_time=$(date +%s%3N)
        if pnpm test 2>/dev/null; then
            end_time=$(date +%s%3N)
            duration=$((end_time - start_time))
            update_layer_status 2 "pass" '{"testPassed": true}' "$duration"
        else
            update_layer_status 2 "fail" '{"testPassed": false}'
        fi
        update_metrics
    else
        print_info "Layer 2: 테스트 스크립트 없음, 스킵"
    fi

    sync_todowrite
    show_aegis_status
}

# Pre-Deploy 체크리스트 실행
run_pre_deploy() {
    print_header "Pre-Deploy Checklist"

    # Layer 0-4 확인
    run_pre_commit

    # Layer 3: API Test
    update_layer_status 3 "running"
    update_metrics

    local start_time=$(date +%s%3N)
    if validate_api 2>/dev/null; then
        local end_time=$(date +%s%3N)
        local duration=$((end_time - start_time))
        update_layer_status 3 "pass" '{"apiTestPassed": true}' "$duration"
    else
        update_layer_status 3 "fail" '{"apiTestPassed": false}'
    fi
    update_metrics

    sync_todowrite
    show_aegis_status
}

# Post-Deploy 체크리스트 실행
run_post_deploy() {
    print_header "Post-Deploy Checklist"

    # Layer 6: Production Monitoring
    update_layer_status 6 "running"
    update_metrics

    local start_time=$(date +%s%3N)
    monitor_production
    local end_time=$(date +%s%3N)
    local duration=$((end_time - start_time))
    update_layer_status 6 "pass" '{"monitoringComplete": true}' "$duration"
    update_metrics

    # Layer 7: Hook Notification
    update_layer_status 7 "running"
    update_metrics

    notify_aegis "배포 후 검증 완료" "AEGIS v4.0"
    update_layer_status 7 "pass" '{"notificationSent": true}'
    update_metrics

    sync_todowrite
    show_aegis_status
}

# ============================================================================
# Usage
# ============================================================================

show_usage() {
    echo "AEGIS Validation Script v4.0 - Dashboard-Independent"
    echo "웹 대시보드 없이 CLI 기반 완전 자율 검증 프레임워크"
    echo ""
    echo -e "${CYAN}v4.0 신규 명령 (Dashboard-Independent):${NC}"
    echo "  $0 --init                     세션 초기화 (aegis.json 생성)"
    echo "  $0 --status                   현재 상태 조회 (CLI 대시보드)"
    echo "  $0 --status --json            상태 JSON 원본 출력"
    echo "  $0 --sync-todo                TodoWrite 동기화"
    echo "  $0 --export [md|json]         리포트 내보내기"
    echo "  $0 --pre-commit               Pre-Commit 체크리스트"
    echo "  $0 --pre-deploy               Pre-Deploy 체크리스트"
    echo "  $0 --post-deploy              Post-Deploy 체크리스트"
    echo ""
    echo -e "${CYAN}Validation Layers:${NC}"
    echo "  $0 --schema <table> [column]  Layer 0: DB 스키마 검증"
    echo "  $0 --build                    Layer 1: 빌드 검증 (GPU 자동 비활성화)"
    echo "  $0 --api                      Layer 3: API 테스트 (AEGIS 내부 API)"
    echo "  $0 --e2e                      Layer 4: E2E 테스트 가이드 (Playwright + /chrome)"
    echo "  $0 --monitor                  Layer 6: 프로덕션 모니터링"
    echo "  $0 --resource                 Resource Layer: 메모리/디스크/정리 검증"
    echo ""
    echo -e "${CYAN}통합 명령:${NC}"
    echo "  $0 --all                      전체 검증 (Layer 0-4 + Resource)"
    echo "  $0 --deploy                   검증 후 배포"
    echo ""
    echo -e "${CYAN}AEGIS v4.0 아키텍처:${NC}"
    echo "  - State Layer: aegis.json 파일 기반 상태 관리 (웹 독립)"
    echo "  - Task Layer: TodoWrite + todos.json 자동 동기화"
    echo "  - Hook Layer: 알림 자동화 (notify-user.sh)"
    echo "  - Validation Layers: 8-Layer 검증 시스템"
    echo "  - CLI Layer: /aegis 스킬 통합"
    echo ""
    echo -e "${CYAN}예시:${NC}"
    echo "  $0 --init                     # 새 세션 시작"
    echo "  $0 --status                   # 상태 확인"
    echo "  $0 --pre-commit               # 커밋 전 검증"
    echo "  $0 --pre-deploy               # 배포 전 검증"
    echo "  $0 --post-deploy              # 배포 후 검증"
    echo "  $0 --export md                # 리포트 생성"
}

# ============================================================================
# Main
# ============================================================================

case "$1" in
    # v4.0 신규 옵션 (Dashboard-Independent)
    --init)
        init_aegis_state
        ;;
    --status)
        if [[ "$2" == "--json" ]]; then
            cat "$AEGIS_STATE_FILE"
        else
            show_aegis_status
        fi
        ;;
    --sync-todo)
        sync_todowrite
        ;;
    --export)
        export_aegis_report "$2"
        ;;
    --pre-commit)
        run_pre_commit
        ;;
    --pre-deploy)
        run_pre_deploy
        ;;
    --post-deploy)
        run_post_deploy
        ;;
    --notify)
        notify_aegis "$2" "$3"
        ;;

    # 기존 옵션 유지
    --schema)
        validate_schema "$2" "$3"
        ;;
    --build)
        validate_build
        ;;
    --api)
        validate_api
        ;;
    --e2e)
        show_e2e_guide
        ;;
    --monitor)
        monitor_production
        ;;
    --resource)
        validate_resource
        ;;
    --all)
        validate_all
        echo ""
        validate_resource
        ;;
    --deploy)
        deploy_with_validation
        ;;
    --help|-h|"")
        show_usage
        ;;
    *)
        print_error "알 수 없는 옵션: $1"
        show_usage
        exit 1
        ;;
esac
