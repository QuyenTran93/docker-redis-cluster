#!/bin/sh

if [ "$1" = 'redis-cluster' ]; then
    # Allow passing in cluster IP by argument or environmental variable
    IP="${2:-$IP}"

    if [ -z "$IP" ]; then # If IP is unset then discover it
        IP=$(hostname -I)
    fi

    echo " -- IP Before trim: '$IP'"
    IP=$(echo ${IP}) # trim whitespaces
    echo " -- IP Before split: '$IP'"
    IP=${IP%% *} # use the first ip
    echo " -- IP After trim: '$IP'"

    if [ -z "$INITIAL_PORT" ]; then # Default to port 7000
      INITIAL_PORT=7000
    fi

    if [ -z "$MASTERS" ]; then # Default to 3 masters
      MASTERS=3
    fi

    if [ -z "$SLAVES_PER_MASTER" ]; then # Default to 1 slave for each master
      SLAVES_PER_MASTER=1
    fi

    if [ -z "$BIND_ADDRESS" ]; then # Default to any IPv4 address
      BIND_ADDRESS=0.0.0.0
    fi

    max_port=$(($INITIAL_PORT + $MASTERS * ( $SLAVES_PER_MASTER  + 1 ) - 1))
    first_standalone=$(($max_port + 1))
    if [ "$STANDALONE" = "true" ]; then
      STANDALONE=2
    fi
    if [ ! -z "$STANDALONE" ]; then
      max_port=$(($max_port + $STANDALONE))
    fi

    for port in $(seq $INITIAL_PORT $max_port); do
      mkdir -p /redis-conf/${port}
      mkdir -p /redis-data/${port}
      if [ -n "$RESET_DATA" -a "$RESET_DATA" = "false" ]; then
        if [ ! -e /redis-data/${port}/nodes.conf ]; then
          RESET_DATA="true"
        fi
      fi
    done

    for port in $(seq $INITIAL_PORT $max_port); do
      if [ -z "$RESET_DATA" -o "$RESET_DATA" = "true" ]; then
        if [ -e /redis-data/${port}/nodes.conf ]; then
          rm /redis-data/${port}/nodes.conf
        fi

        if [ -e /redis-data/${port}/dump.rdb ]; then
          rm /redis-data/${port}/dump.rdb
        fi

        if [ -e /redis-data/${port}/appendonly.aof ]; then
          rm /redis-data/${port}/appendonly.aof
        fi
      fi
      if [ -z "$PROTECTED_MODE" -o "$PROTECTED_MODE" = "true" ]; then
      	protectedmode="protected-mode yes"
      elif [ "$PROTECTED_MODE" = "false" ]; then
      	protectedmode="protected-mode no"
      fi


      if [ -n "$CLUSTER_ANNOUNCE_HOSTNAME" ]; then
        clusterannouncehostname="cluster-announce-hostname '${CLUSTER_ANNOUNCE_HOSTNAME}'"
        clusterpreferedendpointtype="cluster-preferred-endpoint-type hostname"
      fi

      if [ "$port" -lt "$first_standalone" ]; then
        if [ -n "$PASSWORD" ]; then
          requirepass="requirepass '${PASSWORD}'"
          masterauth="masterauth '${PASSWORD}'"
        fi
        PORT=${port} BIND_ADDRESS=${BIND_ADDRESS} REQUIREPASS=${requirepass} MASTERAUTH=${masterauth} PROTECTED_MODE=${protectedmode} CLUSTER_ANNOUNCE_HOSTNAME=${clusterannouncehostname} CLUSTER_PREFERED_ENDPOINT_TYPE=${clusterpreferedendpointtype} envsubst < /redis-conf/redis-cluster.tmpl > /redis-conf/${port}/redis.conf
        nodes="$nodes $IP:$port"
      else
        if [ -n "$PASSWORD" ]; then
          requirepass="requirepass '${PASSWORD}'"
        fi
        PORT=${port} BIND_ADDRESS=${BIND_ADDRESS} REQUIREPASS=${requirepass} PROTECTED_MODE=${protectedmode} envsubst < /redis-conf/redis.tmpl > /redis-conf/${port}/redis.conf
      fi

      if [ "$port" -lt $(($INITIAL_PORT + $MASTERS)) ]; then
        if [ "$SENTINEL" = "true" ]; then
          PORT=${port} SENTINEL_PORT=$((port - 2000)) envsubst < /redis-conf/sentinel.tmpl > /redis-conf/sentinel-${port}.conf
          cat /redis-conf/sentinel-${port}.conf
        fi
      fi

    done

    bash /generate-supervisor-conf.sh $INITIAL_PORT $max_port > /etc/supervisor/supervisord.conf

    supervisord -c /etc/supervisor/supervisord.conf
    sleep 3

    #
    ## Check the version of redis-cli and if we run on a redis server below 5.0
    ## If it is below 5.0 then we use the redis-trib.rb to build the cluster
    #
    if [ -z "$RESET_DATA" -o "$RESET_DATA" = "true" ]; then
      /redis/src/redis-cli --version | grep -E "redis-cli 3.0|redis-cli 3.2|redis-cli 4.0"
      if [ $? -eq 0 ]
      then
        echo "Using old redis-trib.rb to create the cluster"
        echo "yes" | eval ruby /redis/src/redis-trib.rb create --replicas "$SLAVES_PER_MASTER" "$nodes"
      else
        echo "Using redis-cli to create the cluster"
        if [ -z "$PASSWORD"  ]; then
          echo "yes" | eval /redis/src/redis-cli --cluster create --cluster-replicas "$SLAVES_PER_MASTER" "$nodes"
          password_arg="-a $PASSWORD"
        else
          echo "yes" | eval /redis/src/redis-cli --cluster create --cluster-replicas "$SLAVES_PER_MASTER" -a "$PASSWORD" "$nodes"
        fi
      fi

      if [ "$SENTINEL" = "true" ]; then
        for port in $(seq $INITIAL_PORT $(($INITIAL_PORT + $MASTERS))); do
          redis-sentinel /redis-conf/sentinel-${port}.conf &
        done
      fi
    fi

    tail -f /var/log/supervisor/redis*.log
else
  exec "$@"
fi
