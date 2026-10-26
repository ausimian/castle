import Config

# Two variables for the `CASTLE_ENV_FILE` case in `test/e2e/appup_test.exs`,
# which changes one and unsets the other in the target's file and expects a hot
# install to configure the target from it. Unset, they are what the other cases
# see, and nothing reads them.
config :consumer,
  greeting: System.get_env("CONSUMER_GREETING", "unset"),
  feature: System.get_env("CONSUMER_FEATURE", "off")
