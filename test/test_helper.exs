# Git run by any test (or by a hook script a test starts) must never climb out of
# the test's own directories into this checkout. If a fixture directory loses its
# .git, for example because two test runs share this checkout's tmp/, git would
# otherwise find the checkout's repository and `git add`/`git commit` there.
System.put_env("GIT_CEILING_DIRECTORIES", Path.expand("../tmp", __DIR__))

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(HarnessForge.Repo, :manual)
