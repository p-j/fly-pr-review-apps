#!/bin/sh -l

set -ex

flyctl version

if [ -n "$INPUT_PATH" ]; then
  # Allow user to change directories in which to run Fly commands.
  cd "$INPUT_PATH" || exit
fi

REPO_NAME=$(echo $GITHUB_REPOSITORY | tr "/" "-" | tr "[:upper:]" "[:lower:]" | tr "[:punct:]" "-")
EVENT_TYPE=$(jq -r .action /github/workflow/event.json)

# Default the Fly app name to pr-{number}-{repo_name}
pr_number="${INPUT_PRNUMBER:-$(jq -r .number /github/workflow/event.json)}"
app="${INPUT_NAME:-pr-$pr_number-$REPO_NAME}"
region="${INPUT_REGION:-${FLY_REGION:-iad}}"
org="${INPUT_ORG:-${FLY_ORG:-personal}}"
image="$INPUT_IMAGE"
config="${INPUT_CONFIG:-fly.toml}"
dockerfile="$INPUT_DOCKERFILE"
ignorefile="$INPUT_IGNOREFILE"
postgres_username="${INPUT_PGUSERNAME:-$app}"
postgres_database="${INPUT_PGDBNAME:-$app}"
created=0

if ! echo "$app" | grep "$pr_number"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

# PR was closed - remove the Fly app if one exists and exit.
if [ "$EVENT_TYPE" = "closed" ]; then
  flyctl apps destroy "$app" -y || true
  exit 0
fi

# Deploy the Fly app, creating it first if needed.
if ! flyctl status --app "$app"; then
  if [ "$config" != "fly.toml" ]; then
    if [ -f "fly.toml" ]; then
      cp fly.toml fly.toml.bak
      cp "$config" fly.toml
    fi
  fi
  # Create the Fly app.
  flyctl launch --yes --no-deploy --copy-config --name "$app" --image "$image" --regions "$region" --org "$org"
  if [ -f "fly.toml.bak" ]; then
    mv fly.toml.bak fly.toml
  fi
  created=1
fi

# Set secrets if specified.
if [ -n "$INPUT_SECRETS" ]; then
  echo $INPUT_SECRETS | tr " " "\n" | flyctl secrets import --app "$app"
fi

# Attach postgres cluster to the app if specified.
if [ -n "$INPUT_POSTGRES" ]; then
  flyctl postgres attach --yes "$INPUT_POSTGRES" --app "$app" --database-name "$postgres_database" --database-user "$postgres_username" || true
fi

# Build args handling
build_args=""
if [ -n "$INPUT_DOCKERBUILDARGS" ]; then
  for arg in $INPUT_DOCKERBUILDARGS; do
    build_args="$build_args --build-arg $arg"
  done
fi

# Deploy or update the Fly app.
if [ "$INPUT_UPDATE" != "false" ]; then
  flyctl deploy --yes --config "$config" --dockerfile="$dockerfile" --ignorefile="$ignorefile" --app "$app" --regions "$region" --image "$image" --strategy immediate $build_args
elif [ "$created" -eq 1 ]; then
  flyctl deploy --yes --config "$config" --dockerfile="$dockerfile" --ignorefile="$ignorefile" --app "$app" --regions "$region" --image "$image" --strategy immediate $build_args
fi

# # Scale the VM
# if [ -n "$INPUT_VM" ]; then
#   flyctl scale --app "$app" vm "$INPUT_VM"
# fi
# if [ -n "$INPUT_MEMORY" ]; then
#   flyctl scale --app "$app" memory "$INPUT_MEMORY"
# fi
# if [ -n "$INPUT_COUNT" ]; then
#   flyctl scale --app "$app" count "$INPUT_COUNT"
# fi

# Make some info available to the GitHub workflow.
fly status --app "$app" --json >status.json
hostname=$(jq -r .Hostname status.json)
appid=$(jq -r .ID status.json)
echo "hostname=$hostname" >> $GITHUB_OUTPUT
echo "url=https://$hostname" >> $GITHUB_OUTPUT
echo "id=$appid" >> $GITHUB_OUTPUT
echo "name=$app" >> $GITHUB_OUTPUT