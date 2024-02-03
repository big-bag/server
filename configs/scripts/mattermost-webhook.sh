#!/usr/bin/env bash

export MATTERMOST_WEBHOOK_NAME=$MATTERMOST_CHANNEL_NAME

case `
  $CONTAINERS_BINARY exec mattermost mmctl webhook list \
    $MATTERMOST_TEAM \
    --local |
  grep $MATTERMOST_WEBHOOK_NAME > /dev/null
  echo $?
` in
  "1" )
    $CONTAINERS_BINARY exec mattermost mmctl webhook create-incoming \
      --user $MATTERMOST_USERNAME@$DOMAIN_NAME_INTERNAL \
      --display-name $MATTERMOST_WEBHOOK_NAME \
      --channel $MATTERMOST_TEAM:$MATTERMOST_CHANNEL \
      --lock-to-channel \
      --local
  ;;
  "0" )
    export MATTERMOST_WEBHOOK_ID=$(
      $CONTAINERS_BINARY exec mattermost mmctl webhook list \
        $MATTERMOST_TEAM \
        --local |
      grep $MATTERMOST_WEBHOOK_NAME |
      awk '{ print $3 }' |
      sed 's/(//g'
    )
    $CONTAINERS_BINARY exec mattermost mmctl webhook modify-incoming \
      $MATTERMOST_WEBHOOK_ID \
      --display-name $MATTERMOST_WEBHOOK_NAME \
      --channel $MATTERMOST_TEAM:$MATTERMOST_CHANNEL \
      --lock-to-channel \
      --local
  ;;
esac

export MATTERMOST_WEBHOOK_ID=$(
  $CONTAINERS_BINARY exec mattermost mmctl webhook list \
    $MATTERMOST_TEAM \
    --local |
  grep $MATTERMOST_WEBHOOK_NAME |
  awk '{ print $3 }' |
  sed 's/(//g'
)

exec $@
