sandbox = LibTmux.Test.SandboxGuard.enter!()

ExUnit.start(exclude: [:integration])
ExUnit.after_suite(fn _result -> LibTmux.Test.SandboxGuard.leave!(sandbox) end)
