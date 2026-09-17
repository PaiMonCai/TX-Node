from pathlib import Path
Path('docs').mkdir(parents=True, exist_ok=True)
exec(compile(Path('.github/scripts/apply-standalone-clean.py').read_text(encoding='utf-8'), '.github/scripts/apply-standalone-clean.py', 'exec'))
