#! /bin/bash

#Purpose: Run the preproccessing genomic stages on ADAM as fast as possible. Hand variant-ready reads over to an external Variant Caller
# consider var for spark home

set -e
set -x
set -o pipefail

export ADAM_DRIVER_MEMORY="55g"
export ADAM_EXECUTOR_MEMORY="55g"
export SPARK_HOME="/root/spark"
export ADAM_OPTS="--conf spark.eventLog.enabled=true --conf spark.worker.timeout=500"
#export ADAM_OPTS="--conf spark.shuffle.service.enable=true"

#Get spark -s3 downloader
curl -O https://s3-us-west-2.amazonaws.com/bd2k-artifacts/adam/spark-s3-downloader-0.1-SNAPSHOT.jar

#Get the ADAM jar
curl -O https://s3-us-west-2.amazonaws.com/bd2k-artifacts/adam/adam-core_2.10-0.16.1-SNAPSHOT.9f0f41a.jar \

Time=/usr/bin/time
ADAM_HOME=~/adam-core_2.10-0.16.1-SNAPSHOT.9f0f41a.jar
hdfs_root=hdfs://spark-master:8020
USER=ubuntu
Input1=FEEDME

# pull $Input1 from s3 using s3-downloader
/opt/sparkbox/spark/bin/spark-submit \
    ~/spark-s3-downloader-0.1-SNAPSHOT.jar \
    s3://bd2k-test-data/${Input1}.bam \
    ${hdfs_root}/${Input1}.bam

# download dbsnp file for bqsr step
cd /mnt
wget ftp://ftp-trace.ncbi.nih.gov/1000genomes/ftp/technical/reference/dbsnp132_20101103.vcf.gz
gunzip dbsnp132_20101103.vcf.gz
mv dbsnp132_20101103.vcf dbsnp_132.vcf
#put file into hdfs
/opt/sparkbox/hadoop/bin/hadoop fs -put /mnt/dbsnp_132.vcf

# convert known snps file to adam variants file
$Time ${ADAM_HOME}/bin/adam-submit vcf2adam \
    ${hdfs_root}/user/${USER}/dbsnp_132.vcf \
    ${hdfs_root}/user/${USER}/dbsnp_132.var.adam \
    -onlyvariants \
    > convert_known_snps_2adam.report 2>&1

#remove known snps vcf
/opt/sparkbox/hadoop/bin/hadoop fs -rmr \
    ${hdfs_root}/user/${USER}/dbsnp_132.vcf

# START PIPELINE

# convert to adam, and remove bam
$Time ${ADAM_HOME}/bin/adam-submit transform \
    ${hdfs_root}/user/${USER}/$Input1.bam \
    ${hdfs_root}/user/${USER}/$Input1.adam \
    > convert_bam2adam.report 2>&1

/opt/sparkbox/hadoop/bin/hadoop fs -rmr \
    ${hdfs_root}/user/${USER}/$Input1.bam

# mark duplicate reads
$Time ${ADAM_HOME}/bin/adam-submit transform \
    ${hdfs_root}/user/${USER}/$Input1.adam \
    ${hdfs_root}/user/${USER}/$Input1.mkdup.adam \
    -mark_duplicate_reads \
    > markDups.report 2>&1

#remove .adam input file
/opt/sparkbox/hadoop/bin/hadoop fs -rmr \
    ${hdfs_root}/user/${USER}/$Input1.adam

# realign indels
$Time ${ADAM_HOME}/bin/adam-submit transform \
    ${hdfs_root}/user/${USER}/$Input1.mkdup.adam \
    ${hdfs_root}/user/${USER}/$Input1.ri.adam \
    -realign_indels \
    > realignIndels.report 2>&1

#remove mkdup.adam input
/opt/sparkbox/hadoop/bin/hadoop fs -rmr \
    ${hdfs_root}/user/${USER}/$Input1.mkdup.adam

# recalibrate quality scores
$Time ${ADAM_HOME}/bin/adam-submit transform \
    ${hdfs_root}/user/${USER}/$Input1.ri.adam \
    ${hdfs_root}/user/${USER}/$Input1.bqsr.adam \
    -recalibrate_base_qualities \
    -known_snps ${hdfs_root}/user/${USER}/dbsnp_132.var.adam \
    > BQSR.report 2>&1

/opt/sparkbox/hadoop/bin/hadoop fs -rmr \
    ${hdfs_root}/user/${USER}/dbsnp_132.var.adam

# Convert .adam file back to bam for external Genotyper
$Time ${ADAM_HOME}/bin/adam-submit transform \
    ${hdfs_root}/user/${USER}/$Input1.bqsr.adam \
    ${hdfs_root}/user/${USER}/$Input1.bqsr.bam \
    > convert_adam2bam.report 2>&1

#HERE BEGINS VARIANT CALLING STEPS USING .bqsr.bam as the input