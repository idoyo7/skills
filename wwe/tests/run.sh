#!/usr/bin/env bash
# md_shield.py 테스트 하네스 러너.
# 하네스를 실행하고 결과를 요약한 뒤, 하네스의 종료 코드를 그대로 전달한다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="${SCRIPT_DIR}/test_md_shield.py"
SHIELD="${SCRIPT_DIR}/../scripts/md_shield.py"

echo "=================================================================="
echo "humanize-docs / md_shield.py 테스트 러너"
echo "  하네스 : ${HARNESS}"
echo "  대상   : ${SHIELD}"
if [[ ! -f "${SHIELD}" ]]; then
  echo "  상태   : md_shield.py 없음 — 구현 대기 중 (테스트는 스킵으로 처리됨)"
else
  echo "  상태   : md_shield.py 발견됨"
fi
echo "=================================================================="

python3 "${HARNESS}"
RC=$?

echo "=================================================================="
case "${RC}" in
  0)
    echo "결과: 전체 통과 (exit ${RC})"
    ;;
  *)
    echo "결과: 실패/스킵 포함 (exit ${RC}) — 위 unittest 출력에서 FAIL/ERROR/skipped 사유를 확인하세요."
    ;;
esac
echo "=================================================================="

# ---------------------------------------------------------------------------
# llm_signature.py (L1~L14 레이아웃 지문 스코어러) 회귀 테스트 — 위 md_shield
# 테스트 블록은 건드리지 않고 파일 끝에 추가 실행만 덧붙인다.
# ---------------------------------------------------------------------------

SIG_HARNESS="${SCRIPT_DIR}/test_llm_signature.py"
SIG_SCRIPT="${SCRIPT_DIR}/../scripts/llm_signature.py"

echo "=================================================================="
echo "humanize-docs / llm_signature.py 테스트 러너"
echo "  하네스 : ${SIG_HARNESS}"
echo "  대상   : ${SIG_SCRIPT}"
if [[ ! -f "${SIG_SCRIPT}" ]]; then
  echo "  상태   : llm_signature.py 없음 — 구현 대기 중 (테스트는 스킵으로 처리됨)"
else
  echo "  상태   : llm_signature.py 발견됨"
fi
echo "=================================================================="

python3 "${SIG_HARNESS}"
SIG_RC=$?

echo "=================================================================="
case "${SIG_RC}" in
  0)
    echo "결과: 전체 통과 (exit ${SIG_RC})"
    ;;
  *)
    echo "결과: 실패/스킵 포함 (exit ${SIG_RC}) — 위 unittest 출력에서 FAIL/ERROR/skipped 사유를 확인하세요."
    ;;
esac
echo "=================================================================="

if [[ "${RC}" -eq 0 ]]; then
  RC="${SIG_RC}"
fi

# ---------------------------------------------------------------------------
# heading_anchor.py (헤딩 슬러그 재계산 · 같은 파일 내부 앵커 치환 · 게이트 D)
# 회귀 테스트 — 위 두 블록은 건드리지 않고 파일 끝에 추가 실행만 덧붙인다.
# ---------------------------------------------------------------------------

HA_HARNESS="${SCRIPT_DIR}/test_heading_anchor.py"
HA_SCRIPT="${SCRIPT_DIR}/../scripts/heading_anchor.py"

echo "=================================================================="
echo "humanize-docs / heading_anchor.py 테스트 러너"
echo "  하네스 : ${HA_HARNESS}"
echo "  대상   : ${HA_SCRIPT}"
if [[ ! -f "${HA_SCRIPT}" ]]; then
  echo "  상태   : heading_anchor.py 없음 — 구현 대기 중 (테스트는 스킵으로 처리됨)"
else
  echo "  상태   : heading_anchor.py 발견됨"
fi
echo "=================================================================="

python3 "${HA_HARNESS}"
HA_RC=$?

echo "=================================================================="
case "${HA_RC}" in
  0)
    echo "결과: 전체 통과 (exit ${HA_RC})"
    ;;
  *)
    echo "결과: 실패/스킵 포함 (exit ${HA_RC}) — 위 unittest 출력에서 FAIL/ERROR/skipped 사유를 확인하세요."
    ;;
esac
echo "=================================================================="

if [[ "${RC}" -eq 0 ]]; then
  RC="${HA_RC}"
fi

exit "${RC}"
