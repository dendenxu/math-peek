"""Full formula fixtures for an isolated terminal; select one page to avoid clipping."""
import json
from pathlib import Path
import sys

mode = "boxed" if "--boxed" in sys.argv else "matrices" if "--matrices" in sys.argv else "kalman"
source = json.loads(Path(__file__).with_name("full_formula_fixtures.json").read_text())[mode]
source = source.strip()
print("MATHPEEK FULL FORMULA DEMO")
print("Fixture mode: " + mode)
print("Tiny reset: $x$")
print()
print("Full formula:")
print(source)
print("END FULL FORMULA")
input("\nPress Enter to close this isolated fixture. ")
