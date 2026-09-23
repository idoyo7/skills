#!/usr/bin/env python3
"""output-styles/korean-plain.md가 wwe/references/author-tics.txt의 모든 시드
표현을 실제로 담고 있는지 검증한다.

korean-plain.md는 reply-check 훅이 사후에 잡는 패턴을 미리 피하게 하는
문서라, 훅의 시드 목록과 어긋나면 예방 효과가 떨어진다. 시드 파일이 바뀌어도
문서를 깜빡 놓치지 않게 이 테스트로 묶어둔다.

파싱 규칙은 reply-check.py의 _load_seeds()와 동일하게 맞춘다: 빈 줄과 '#'로
시작하는 줄(섹션 헤더·보류 주석 포함)은 건너뛰고, '=>' 앞부분을 표현으로
본다.
"""
import unittest
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
_SEED_PATH = _REPO_ROOT / "wwe/references/author-tics.txt"
_DOC_PATH = _REPO_ROOT / "output-styles/korean-plain.md"


def _load_seed_phrases() -> list[str]:
    seeds: list[str] = []
    with open(_SEED_PATH, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key = line.split("=>", 1)[0].strip()
            if key:
                seeds.append(key)
    return seeds


class TestKoreanPlainSeedCoverage(unittest.TestCase):
    def test_seed_files_exist(self):
        self.assertTrue(_SEED_PATH.exists(), f"시드 파일 없음: {_SEED_PATH}")
        self.assertTrue(_DOC_PATH.exists(), f"output-style 문서 없음: {_DOC_PATH}")

    def test_every_seed_phrase_appears_in_doc(self):
        seeds = _load_seed_phrases()
        self.assertGreater(len(seeds), 0, "author-tics.txt에서 시드를 못 읽었다")
        doc = _DOC_PATH.read_text(encoding="utf-8")
        missing = [s for s in seeds if s not in doc]
        self.assertEqual(
            missing, [],
            f"korean-plain.md에 빠진 시드 {len(missing)}개: {missing}",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
