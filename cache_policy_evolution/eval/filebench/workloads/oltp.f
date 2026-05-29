# FileBench OLTP workload
# Emulates a database OLTP workload: random reads/writes to large files

set $dir=/tmp/filebench
set $nfiles=10
set $meandirwidth=1000000
set $filesize=10485760
set $nthreads=200
set $iosize=8192
set $nshadow=200
set $navail=1

define fileset name=dbfileset,path=$dir,size=$filesize,entries=$nfiles,dirwidth=$meandirwidth,prealloc=100
define fileset name=shadowfileset,path=$dir,size=$filesize,entries=$nshadow,dirwidth=$meandirwidth,prealloc=100

define process name=oltp,instances=1
{
  thread name=oltpthread,memsize=10m,instances=$nthreads
  {
    flowop read name=oltp-read,filesetname=dbfileset,random,iosize=$iosize,fd=1
    flowop hog name=oltp-hog,value=10
    flowop read name=oltp-read2,filesetname=dbfileset,random,iosize=$iosize,fd=1
    flowop hog name=oltp-hog2,value=10
    flowop read name=oltp-read3,filesetname=dbfileset,random,iosize=$iosize,fd=1
    flowop hog name=oltp-hog3,value=10
    flowop read name=oltp-read4,filesetname=dbfileset,random,iosize=$iosize,fd=1
    flowop hog name=oltp-hog4,value=10
    flowop write name=oltp-write,filesetname=dbfileset,random,iosize=$iosize,fd=1
    flowop hog name=oltp-hog5,value=10
    flowop write name=oltp-log,filesetname=shadowfileset,random,iosize=$iosize,fd=2
    flowop hog name=oltp-hog6,value=1
  }
}

run 60
