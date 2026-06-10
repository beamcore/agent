ExUnit.start()

{:ok, _started} = Application.ensure_all_started(:agent)

policy_root =
  Path.join(System.tmp_dir!(), "beamcore_test_policy_root_#{System.unique_integer([:positive])}")

File.mkdir_p!(Path.join(policy_root, ".beamcore"))

example = Path.expand("../.beamcore/policy.example.json", __DIR__)

if File.exists?(example) do
  File.cp!(example, Path.join(policy_root, ".beamcore/policy.example.json"))
end

Application.put_env(:agent, :project_policy_root, policy_root)
