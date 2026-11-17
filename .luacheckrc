std = "lua51"
read_globals = { "rex" }
-- Allow the existing single-line command vectors and test fixtures without disabling the check.
max_line_length = 180

files["tests/unit-runner.lua"] = { globals = { "rex" } }
