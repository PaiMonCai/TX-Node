from pathlib import Path
Path('docs').mkdir(parents=True, exist_ok=True)
src = Path('.github/scripts/apply-standalone-clean.py').read_text(encoding='utf-8')
src = src.replace('for path in (Path("Makefile"), Path(".github/workflows/ci.yml"), Path("docs/standalone.md")):', 'for path in (Path("Makefile"), Path(".github/workflows/ci.yml")):')
exec(compile(src, '.github/scripts/apply-standalone-clean.py', 'exec'))
