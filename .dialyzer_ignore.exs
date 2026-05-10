# Suppress dialyzer warnings on test/support files.
# `Supabase.init_client/3` has a binary spec that dialyzer can't prove from
# interpolated `"http://localhost:#{port}"` URLs.
[
  {"test/support/integration/case.ex"}
]
