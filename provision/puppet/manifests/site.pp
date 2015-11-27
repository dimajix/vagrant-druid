# This puppet file simply installs the required packages for provisioning and gets the base 
# provisioning from the correct repos. The VM can then provision itself from there. 

package {puppet:ensure=> [latest,installed]}
package {ruby:ensure=> [latest,installed]}


# Configure Cloudera repositories
stage { 'init':
  before => Stage['main'],  
}
class { '::cloudera::cdh5::repo':
  version   => '5.4.8',
  stage => init
}
class { '::cloudera::cm5::repo':
  version   => '5.4.8',
  stage => init
}
class { '::osfixes::ubuntu::hosts':
  stage => init
}

class java_config {
    # Make sure Java is installed on hosts, select specific version
    class { 'java':
        distribution => 'jre'
    } 
}

class mysql_config {
    class { 'mysql::bindings':
      java_enable => true,
    }
}


# Put global Hadoop configuration into a dedicated class, which will
# be included by relevant nodes. This way only nodes which need Hadoop
# will get Hadoop and its dependencies.
class hadoop_config {
    include java_config

    # Modify global Hadoop settings
    class{ "hadoop":
      hdfs_hostname => "namenode.${domain}",
      yarn_hostname => "namenode.${domain}",
      slaves => [ "datanode1.${domain}", "datanode2.${domain}" ],
      frontends => [ "client.${domain}" ],
      features => { 'aggregation' => 1 },
      perform => false,
      # security needs to be disabled explicitly by using empty string
      realm => '',
      properties => {
        # Please no replication in our virtual dev cluster
        'dfs.replication' => 1,
        'hadoop.proxyuser.hive.groups' => 'hive,users,supergroup',
        'hadoop.proxyuser.hive.hosts' => '*',
        'hadoop.proxyuser.oozie.groups' => '*',
        'hadoop.proxyuser.oozie.hosts'  => '*',
        # Limit CPU usage
        'yarn.nodemanager.resource.cpu-vcores' => '4',
        # Enable log aggregation
        'yarn.log-aggregation-enable' => 'true',
        'yarn.log.server.url' => 'http://${yarn.timeline-service.webapp.address}/jobhistory/logs',
        'yarn.timeline-service.enabled' => 'true',
        'yarn.timeline-service.hostname' => "namenode.${domain}",
        'yarn.timeline-service.generic-application-history.enabled' => 'true',
        'yarn.timeline-service.address' => '${yarn.timeline-service.hostname}:10200',
        'yarn.timeline-service.webapp.address' => '${yarn.timeline-service.hostname}:19888',
        # Enable Job History Server
        'mapreduce.jobhistory.address' => "namenode.${domain}:10020",
        'mapreduce.jobhistory.webapp.address' => "namenode.${domain}:19888",
        # Enable external shuffle service (for Spark)
        'yarn.nodemanager.aux-services' => 'spark_shuffle,mapreduce_shuffle',
        'yarn.nodemanager.aux-services.spark_shuffle.class' => 'org.apache.spark.network.yarn.YarnShuffleService',
        # Turn off security
        'dfs.namenode.acls.enabled' => 'false',
        'dfs.permissions.enabled' => 'false',
        # Enable shortcircuit reads for impala
        'dfs.client.read.shortcircuit' => 'true',
        'dfs.domain.socket.path' => '/var/lib/hadoop-hdfs/dn_socket',
        'dfs.client.file-block-storage-locations.timeout.millis' => '10000',
        'dfs.datanode.hdfs-blocks-metadata.enabled' => 'true'
      } 
    }

    # Setup basic hadoop configuration
    include hadoop::common::install
    include hadoop::common::config
    
    Class['java'] ->
    Class['hadoop::common::install'] ->
    Class['hadoop::common::config']
}


class spark_config {
    include hadoop_config
    
    class { "spark": 
      yarn_namenode => "namenode.${domain}",
      properties => {
        'spark.eventLog.dir' => "hdfs://namenode.${domain}/user/spark/applicationHistory",
        'spark.eventLog.enabled' => 'true',
        'spark.serializer' => 'org.apache.spark.serializer.KryoSerializer',
        'spark.shuffle.service.enabled' => 'true',
        'spark.shuffle.service.port' => '7337',
        'spark.yarn.historyServer.address' => "http://namenode.${domain}:19888",
        'spark.driver.extraLibraryPath' => '/usr/lib/hadoop/lib/native',
        'spark.executor.extraLibraryPath' => '/usr/lib/hadoop/lib/native',
        'spark.yarn.am.extraLibraryPath' => '/usr/lib/hadoop/lib/native'
      }
    }
}


class druid_config {
  include hadoop_config

  class { 'druid':
    version     => '0.8.2',
    install_dir => '/opt',
    config_dir  => '/etc/druid',
    storage_type => 'hdfs',
    hdfs_directory => '/user/druid',
    extensions_local_repository => '/opt/druid/extensions-repo',
    extensions_coordinates => ['io.druid.extensions:mysql-metadata-storage'],
    metadata_storage_type => 'mysql',
    metadata_storage_connector_user => 'druid',
    metadata_storage_connector_password => 'druid',
    metadata_storage_connector_uri => "jdbc:mysql://mysql.${domain}:3306/druid?characterEncoding=UTF-8",
    zk_service_host => "zookeeper1.${domain}"
  }
}


node 'namenode' {
  include hadoop_config
  include spark_config
  # HDFS
  include hadoop::namenode
  # YARN
  include hadoop::resourcemanager
  # MAPRED
  include hadoop::historyserver
}


node 'drbroker' {
  include hadoop_config
  include druid_config
  
  # client
  include hadoop::frontend
  # mysql client
  include mysql::client
  # druid broker
  class { 'druid::broker':
    processing_num_threads => 4
  }

  Class['hadoop::common::config'] -> 
  Class['hadoop::frontend']
}


node 'drcoord' {
  include hadoop_config
  include druid_config
  
  # client
  include hadoop::frontend
  # mysql client
  include mysql::client
  # druid coordinator
  include druid::coordinator

  Class['hadoop::common::config'] -> 
  Class['hadoop::frontend']
}


node 'drhistory' {
  include hadoop_config
  include druid_config
  
  # client
  include hadoop::frontend
  # mysql client
  include mysql::client
  # druid coordinator
  class { 'druid::historical':
    processing_num_threads => 4,
    segment_cache_info_dir => '/var/cache/druid/info',
    segment_cache_locations => [ {'path' => '/var/cache/druid/segments', 'maxSize' => '1000000000'} ]
  }

  file { '/var/cache/druid':
    ensure  => directory,
  }
  file { '/var/cache/druid/info':
    ensure  => directory,
    require => File['/var/cache/druid']
  }
  file { '/var/cache/druid/segments':
    ensure  => directory,
    require => File['/var/cache/druid']
  }

  Class['hadoop::common::config'] -> 
  Class['hadoop::frontend']
}


node 'droverlord' {
  include hadoop_config
  include druid_config
  
  # client
  include hadoop::frontend
  # mysql client
  include mysql::client
  # druid indexing overlord
  include druid::indexing::overlord

  Class['hadoop::common::config'] -> 
  Class['hadoop::frontend']
}


node 'drmiddle' {
  include hadoop_config
  include druid_config
  
  # client
  include hadoop::frontend
  # mysql client
  include mysql::client
  # druid indexing middle manager
  include druid::indexing::middle_manager

  Class['hadoop::common::config'] -> 
  Class['hadoop::frontend']
}


node 'drrealtime' {
  include hadoop_config
  include druid_config
  
  # client
  include hadoop::frontend
  # mysql client
  include mysql::client
  # druid realtime
  class { 'druid::realtime':
    processing_num_threads => 4,
  }

  Class['hadoop::common::config'] -> 
  Class['hadoop::frontend']
}


node 'client' {
  include hadoop_config
  include spark_config

  # client
  include hadoop::frontend
  # mysql client
  include mysql::client
  # Spark client
  include spark::frontend

  # Install python for scripting
  class { 'python':
    version    => 'system',
    pip        => present,
    dev        => present,
    virtualenv => present,
    gunicorn   => absent,
    manage_gunicorn => false
  }

  Class['hadoop::common::config'] -> 
  Class['hadoop::frontend'] ->
  Class['spark::frontend']
}


node /datanode[1-9]/ {
  include hadoop_config
  include spark_config

  # slave (HDFS)
  include hadoop::datanode
  # slave (YARN)
  include hadoop::nodemanager
  # Spark worker
  include spark::common

  Class['hadoop::common::config'] -> 
  Class['hadoop::datanode'] ->
  Class['hadoop::nodemanager']
}


node /zookeeper[1-9]/ {
  include java_config
  class { 'zookeeper': hostnames => [ $::fqdn ],  realm => '' }
  Class['java'] ->
  Class['zookeeper']
}


node mysql {
  # MySQL server
  class { 'mysql::server':
    root_password           => '1234',
    remove_default_accounts => true,
    override_options => { 'mysqld' => { 'bind-address' => '0.0.0.0' } }
  }

  # Druid metastore database
  mysql::db { 'druid':
    user     => 'druid',
    password => 'druid',
    host     => '%',
    grant    => ['CREATE', 'SELECT', 'INSERT', 'UPDATE', 'DELETE']
  }
}

