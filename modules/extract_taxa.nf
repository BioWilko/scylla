// module to extract reads and de novo assemble top taxa


// it is possible that no files would be extracted if there were no subsets of reads which matched the criteria
// also note that the reads extracted don't match up with bracken abundance reestimates, although we do use those
// as more accurate numbers when deciding what to pull out (bracken doesn't provide read break down)
// probably want to count up how many have been found here for run log
// ALSO this step will currently "fail" with exitcode 2 if the number of human reads found exceeds the number specified
// in config so could be good dehuman sanity check

process split_kreport {

    label 'process_single'

    conda 'bioconda::biopython=1.78'
    container "biocontainers/pyfastx:2.0.1--py39h3d4b85c_0"

    input:
        tuple val(unique_id), path(kreport)
    output:
        tuple val(unique_id), path("*.kreport_split.txt")
    script:
        """
        split_kraken_report.py \
            -r ${kreport} \
            --splits ${params.kreport_splits}
        """
}

process extract_paired_reads {
    
    label 'process_single'
    label 'process_high_memory'

    errorStrategy {task.exitStatus in 2..3 ? 'ignore' : 'terminate'}

    conda 'bioconda::biopython=1.78 bioconda::tabix=1.11'
    container "biocontainers/pyfastx:2.0.1--py39h3d4b85c_0"

    input:
        tuple val(unique_id), path(fastq1), path(fastq2), path(kraken_assignments), path(kreport), val(min_reads), val(min_percent)
        path taxonomy_dir
    output:
        tuple val(unique_id), path("*.fastq"), emit: reads
        tuple val(unique_id), path("${kreport}_summary.json"), emit: summary
    script:
        """
        extract_kraken_reads.py \
            -s1 ${fastq1} \
            -s2 ${fastq2} \
            -k ${kraken_assignments} \
            -r ${kreport} \
            -t ${taxonomy_dir} \
            -p ${kreport} \
            --include_children \
            --max_human ${params.max_human_reads_before_rejection} \
            --min_count_descendants ${min_reads} \
            --rank ${params.extract_rank} \
            --min_percent ${min_percent}

        PATTERN=(*.f*q)
        if [ ! -f \${PATTERN[0]} ]; then
            echo "Found no output files - maybe there weren't any for this sample"
            exit 3
        fi
        """
}

process extract_reads {

    label 'process_single'
    label 'process_high_memory'
    
    errorStrategy {task.exitStatus in 2..3 ? 'ignore' : 'terminate'}

    conda 'bioconda::biopython=1.78 bioconda::tabix=1.11'
    container "biocontainers/pyfastx:2.0.1--py39h3d4b85c_0"

    input:
        tuple val(unique_id), path(fastq), path(kraken_assignments), path(kreport), val(min_reads), val(min_percent)
        path taxonomy_dir
    output:
        tuple val(unique_id), path("*.f*q"), emit: reads
        tuple val(unique_id), path("${kreport}_summary.json"), emit: summary
    script:
        """
        extract_kraken_reads.py \
            -s ${fastq} \
            -k ${kraken_assignments} \
            -r ${kreport} \
            -t ${taxonomy_dir} \
            -p ${kreport} \
            --include_children \
            --max_human ${params.max_human_reads_before_rejection} \
            --min_count_descendants ${min_reads} \
            --rank ${params.extract_rank} \
            --min_percent ${min_percent}

        PATTERN=(*.f*q)
        if [ ! -f \${PATTERN[0]} ]; then
            echo "Found no output files - maybe there weren't any for this sample"
            exit 3
        fi
        """
}

process bgzip_extracted_taxa {
      
      label 'process_medium'
  
      publishDir path: "${params.outdir}/${unique_id}/reads_by_taxa", mode: 'copy'
  
      conda 'bioconda::biopython=1.78 bioconda::tabix=1.11'
      container "${params.wf.container}:${params.wf.container_version}"
  
      input:
          tuple val(unique_id), path(read_files)
      output:
          tuple val(unique_id), path("*.f*q.gz")
      script:
          """
          for f in \$(ls *.f*q)
            do
            bgzip --threads $task.cpus \$f
            done
          """
}

process merge_read_summary {

    label 'process_single'

    publishDir path: "${params.outdir}/${unique_id}/reads_by_taxa", pattern: "reads_summary_combined.json", mode: 'copy'

    container "${params.wf.container}:${params.wf.container_version}"

    input:
        tuple val(unique_id), path(reads_summary)

    output:
        path "reads_summary_combined.json"
    
    """
    jq -s '.[0]' *_summary.json > reads_summary_combined.json
    """
}


workflow extract_taxa {
    take:
        fastq_ch
        assignments_ch
        kreport_ch
        taxonomy_dir
    main:
        thresholds = params.extract_thresholds
        split_kreport(kreport_ch)
        split_kreport.out.transpose()
            .map { unique_id, kreport -> [unique_id, kreport, kreport.simpleName, thresholds.containsKey(kreport.simpleName)] }
            .branch { unique_id, kreport, key, status ->
                valid: status
                    return tuple( unique_id, kreport, key )
                invalid: !status
                    return tuple( unique_id, kreport, "default" )
                }
            .set { result }
        result.valid.concat(result.invalid)
                    .map { unique_id, kreport, key -> [unique_id, kreport, thresholds.get(key,"false").get("min_reads","false"), thresholds.get(key,"false").get("min_percent","false")] }
                    .set{ kreport_params_ch }

        fastq_ch.combine(assignments_ch, by: 0)
                .combine(kreport_params_ch, by: 0)
                .set{ extract_ch }

        if ( params.paired ){
            extract_paired_reads(extract_ch, taxonomy_dir)
            extract_paired_reads.out.reads
                .set {extracted_taxa}
            extract_paired_reads.out.summary
                .groupTuple()
                .set {reads_summary_ch}
        } else {
            extract_reads(extract_ch, taxonomy_dir)
            extract_reads.out.reads
                .set {extracted_taxa}
            extract_reads.out.summary
                .groupTuple()
                .set {reads_summary_ch}       
        }
        bgzip_extracted_taxa(extracted_taxa)
        merge_read_summary(reads_summary_ch)

}


workflow {
    unique_id = "${params.unique_id}"
    fastq = file(params.fastq, type: "file", checkIfExists:true)
    assignments = file(params.kraken_assignments, type: "file", checkIfExists:true)
    kreport = file(params.kraken_report, type: "file", checkIfExists:true)
    if (unique_id == "null") {
       unique_id = "${fastq.simpleName}"
    }

    fastq_ch = Channel.of([unique_id, fastq])
    assignments_ch = Channel.of([unique_id, assignments])
    kreport_ch = Channel.of([unique_id, kreport])
    taxonomy_dir = file(params.taxonomy, type: "dir", checkIfExists:true)

    extract_taxa(unique_id, fastq_ch, assignments_ch, kreport_ch, taxonomy_dir)
}

