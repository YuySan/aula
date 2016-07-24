#!/bin/bash

export SEL=/liqd/selenium/selenium-server-standalone-2.53.1.jar
export SELENIUM_HOST=localhost
export SELENIUM_HUB_PORT=4444
export SELENIUM_NODE_PORT=5555
export LOG_PATH=/log
export DISPLAY=:1

export SELENIUM_HUB_ARGS=
export SELENIUM_NODE_ARGS=-Dwebdriver.chrome.driver=/usr/lib/chromium-browser/chromedriver

case "$1" in
  start)
    cd /tmp/  # this is all dumping a lot of cores...
    mkdir -p $LOG_PATH

    echo -n "starting Xvfb..."
    nohup Xvfb $DISPLAY > $LOG_PATH/selenium-xvfb.log 2>&1 &
    echo " ok"

    echo -n "starting hub"
    nohup java -jar $SEL -role hub -host $SELENIUM_HOST -port $SELENIUM_HUB_PORT \
          $SELENIUM_HUB_ARGS \
          > $LOG_PATH/selenium-hub.log 2>&1 &
    until (nc -z $SELENIUM_HOST $SELENIUM_HUB_PORT); do echo -n "."; sleep .$RANDOM; done
    echo " ok"

    echo -n "starting node"
    nohup java -jar $SEL -role node -host $SELENIUM_HOST -port $SELENIUM_NODE_PORT \
          -hub http://$SELENIUM_HOST:$SELENIUM_HUB_PORT/grid/register \
          $SELENIUM_NODE_ARGS \
          > $LOG_PATH/selenium-node.log 2>&1 &
    until (nc -z $SELENIUM_HOST $SELENIUM_NODE_PORT); do echo -n "."; sleep .$RANDOM; done
    echo " ok"
    ;;

  stop)
    killall -q -9 java
    killall -q -9 Xvfb
    ;;

  restart)
    $0 stop
    $0 start
    ;;

  *)
    echo "bad arguments"
    ;;

esac