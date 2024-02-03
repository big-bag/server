#!/usr/bin/env bash

export MATTERMOST_CHANNEL=$(
  echo $MATTERMOST_CHANNEL_NAME |
  awk '{print tolower($0)}' |
  sed 's/ /-/g'
)

case `
  $CONTAINERS_BINARY exec mattermost mmctl channel list \
    $MATTERMOST_TEAM \
    --local |
  grep $MATTERMOST_CHANNEL > /dev/null
  echo $?
` in
  "1" )
    $CONTAINERS_BINARY exec mattermost mmctl channel create \
      --team $MATTERMOST_TEAM \
      --name $MATTERMOST_CHANNEL \
      --display-name "$MATTERMOST_CHANNEL_NAME" \
      --private \
      --local
  ;;
  "0" )
    $CONTAINERS_BINARY exec mattermost mmctl channel rename \
      $MATTERMOST_TEAM:$MATTERMOST_CHANNEL \
      --display-name "$MATTERMOST_CHANNEL_NAME" \
      --local

    case `
      $CONTAINERS_BINARY exec mattermost mmctl channel search \
        --team $MATTERMOST_TEAM \
        $MATTERMOST_CHANNEL \
        --json \
        --local |
      jq --raw-output .type
    ` in
      "O" )
        $CONTAINERS_BINARY exec mattermost mmctl channel modify \
          $MATTERMOST_TEAM:$MATTERMOST_CHANNEL \
          --private \
          --local
        echo "'$MATTERMOST_CHANNEL' channel converted to private"
      ;;
      "P" )
        echo "'$MATTERMOST_CHANNEL' channel is already private"
      ;;
    esac

  ;;
esac

$CONTAINERS_BINARY exec mattermost mmctl channel users add \
  $MATTERMOST_TEAM:$MATTERMOST_CHANNEL \
  $MATTERMOST_USERNAME@$DOMAIN_NAME_INTERNAL \
  --local

exec $@
