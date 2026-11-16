"""Shared setup for every test: a local .env file is never read.

src/config.py loads .env when it is imported; a developer's .env (for example
with the AWS TLS settings) would then change what the tests see. python-dotenv
skips loading when PYTHON_DOTENV_DISABLED is set. pytest imports this file
before any test module, and the subprocess tests inherit the variable.
"""
import os

os.environ["PYTHON_DOTENV_DISABLED"] = "1"
