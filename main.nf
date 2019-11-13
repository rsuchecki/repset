#!/usr/bin/env nextflow

//For pretty-printing nested maps etc
import static groovy.json.JsonGenerator.*
// import static groovy.json.JsonSlurper as JsonSlurper

//Otherwise JSON generation triggers stackoverflow when encountering Path objects
jsonGenerator = new groovy.json.JsonGenerator.Options()
                .addConverter(java.nio.file.Path) { java.nio.file.Path p, String key -> p.toUriString() }
                .build()


//Input validation specified elswhere
def validators = new GroovyShell().parse(new File("${baseDir}/groovy/Validators.groovy"))

//Read, parse, validate and sanitize alignment/mapping tools config
def allRequired = ['tool','version','container','index'] //Fields required for each tool in config
def allModes = 'dna2dna|rna2rna|rna2dna' //At leas one mode has to be defined as supported by each tool
def allVersions = validators.validateMappersDefinitions(params.mappersDefinitions, allRequired, allModes)

//Check if specified template files exist
validators.validateTemplatesAndScripts(params.mappersDefinitions, (['index']+(allModes.split('\\|') as List)), "${baseDir}/templates")

//Read, sanitize and validate alignment/mapping param sets
validators.validateMapperParamsDefinitions(params.mapperParamsDefinitions, allVersions, allModes)

//Parse, sanitize and validate input dataset definitions
def requiredInputFields = ['species','version','fasta','seqtype']
validators.validateInputDefinitions(params.references, requiredInputFields, ['gff'])

if(params.justvalidate) {
  log.info "Finished validating input config, exiting. Run without --justvalidate to proceed further."
  System.exit 0
}

//Validated now, so gobble up mappers...
// mappersChannel = Channel.from(params.mappersDefinitions)
Channel.from(params.mappersDefinitions)
  .filter{ params.mappers == 'all' || it.tool.matches(params.mappers) } //TODO Could allow :version
  // .tap { mappersMapChannel }
  // .map { it.subMap(allRequired)} //Exclude mapping specific fields from indexing process to avoid re-indexing e.g. on changes made to a mapping template
  // .set { mappersIdxChannel }
  .into { mappersIdxChannel; mappersMapChannel }


//...and their params definitions
mappersParamsChannel = Channel.from(params.mapperParamsDefinitions)

//one or more mapping mode
mapModesChannel = Channel.from(params.mapmode.split('\\||,'))

/*
 * Add to or overwrite map content recursively
 * Used to enable the use of NF -params-file opt such that params can be added and not just overwritten
 */
Map.metaClass.addNested = { Map rhs ->
    def lhs = delegate
    rhs.each { k, v -> lhs[k] = lhs[k] in Map ? lhs[k].addNested(v) : v }
    lhs
}

/*
  Generic method for extracting a string tag or a file basename from a metadata map
 */
def getTagFromMeta(meta, delim = '_') {
  return meta.species+delim+meta.version //+(trialLines == null ? "" : delim+trialLines+delim+"trialLines")
}

/*
  Given a file with '=' delimited key value pairs on each line
  (this could e.g. be .command.trace)
  parse and store in map provided,
 */
def parseFileMap(filemap, map, subset = false) {
  filemap.splitEachLine("=", { record ->
      if(record.size() > 1 && (subset == false || record[0] in subset)) {
        v = record[1]
        map."${record[0]}" = v.isInteger() ? v.toInteger() : v.isDouble() ? v.toDouble() : v
      }
    })
}

/*
  Simplistic method for checking if String is URL
*/
String.metaClass.isURL() {
   delegate.matches("^(https?|ftp)://.*\$")
}

def helpMessage() {
  log.info"""
  Usage:

  nextflow run csiro-crop-informatics/biokanga-manuscript -profile singularity
  nextflow run csiro-crop-informatics/biokanga-manuscript -profile docker

  Default params:
  """.stripIndent()
  println(prettyPrint(toJson(params)))
  // println(prettyPrint(toJson(config)))
  // println(prettyPrint(toJson(config.process)))
}

// Show help message
params.help = false
if (params.help){
    helpMessage()
    exit 0
}

/*
 1. Input pointers to FASTA converted to files, NF would fetch remote as well and create tmp files,
    but avoiding that as may not scale with large genomes, prefer to do in process.
 2. Conversion would not have been necessary and script could point directly to meta.fasta
    but local files might not be on paths automatically mounted in the container.
*/
Channel.from(params.references)
.combine(Channel.from('fasta','gff')) //duplicate each reference record
.filter { meta, fileType -> meta.containsKey(fileType)} //exclude gff record if no gff declared
.tap { refsToStage } //download if URL
.filter { meta, fileType ->  !(meta."${fileType}").isURL() } //Exclude URLs
.map { meta, fileType ->  [meta, fileType, file(meta."${fileType}")] } //file declaration required for correct binding of source path
// .view { it -> groovy.json.JsonOutput.prettyPrint(jsonGenerator.toJson(it))}
.set { refsToStageLocal }


process stageRemoteInputFile {
  tag{meta.subMap(['species','version'])+[fileType: fileType]}
  errorStrategy 'finish'
  storeDir {  "${workDir}/downloaded"  } //- perhaps more robust as workdir is mounted in singularity unlike outdir?

  input:
    set val(meta), val(fileType) from refsToStage //fastaChn.mix(gffChn)

  output:
    set val(outmeta), file(outfile)  into stagedFilesRemote

  when:
    (meta."${fileType}").isURL()

  script:
    basename=getTagFromMeta(meta)
    outfile =  "${basename}.${fileType}"
    outmeta = meta.subMap(['species', 'version','seqtype'])
    fpath = meta."${fileType}"
    decompress = fpath.matches("^.*\\.gz\$") ?  "| gunzip --stdout " :  " "
    """curl ${fpath} ${decompress} > ${outfile}"""
}

process stageLocalInputFile {
  tag{meta.subMap(['species','version'])+[fileType: fileType]}
  errorStrategy 'finish'

  input:
    set val(meta), val(fileType), file(infile) from refsToStageLocal

  output:
    set val(outmeta), file(outfile)  into stagedFilesLocal

  script:
    basename=getTagFromMeta(meta)
    outfile = "${basename}.${fileType}"
    outmeta = meta.subMap(['species', 'version','seqtype'])
    if((infile.name).matches("^.*\\.gz\$")){ //GZIPPED
      """gunzip --stdout  ${infile}  > ${outfile} """
    } else { //FLAT
      """cp -s  ${infile} ${outfile}"""
    }
}

// referencesOnly = Channel.create()
// referencesForTranscriptomeExtraction = Channel.create()
stagedFilesRemote.mix(stagedFilesLocal)
  // .view()
  .groupTuple() //match back fasta with it's gffif available
  // .view { meta, files, seqtype -> "meta: ${meta}\nfiles: ${files}\nseqtype: ${seqtype}"}
  // .map { meta, files ->
  //   files.sort { a,b -> a.name.substring(a.name.lastIndexOf('.')+1) <=> b.name.substring(b.name.lastIndexOf('.')+1) } //ensure gff goes after fasta based on extension
  //   [meta, files]
  // }
  // .view { it -> println(groovy.json.JsonOutput.prettyPrint(jsonGenerator.toJson(it)))}
  .set { stagedReferences }




process faidxGenomeFASTA {
  tag("${refmeta}")
  label 'samtools'

  input:
    set val(refmeta), file(infiles) from stagedReferences

  output:
    set val(refmeta), file("${ref}.fai") into genomeIndicesForReadCoordinateConversion
    set val(refmeta), file(ref), file("${ref}.fai") into genomesForIndexing, genomesForRnfSimReads
    set val(refmeta), file(ref), file("${ref}.fai"), file("${gff}") optional true into referencesForTranscriptomeExtraction //refsForIndexing

  script:
  ref = infiles[infiles.findIndexOf { fname -> fname =~ /\.fasta$/ }]
  gffIdx = infiles.findIndexOf { fname -> fname =~ /\.gff$/ }
  gff = gffIdx >= 0 ? infiles[gffIdx] : 'NO_GFF_HERE'
  """
  samtools faidx ${ref}
  """
}

// referencesOnly.view {println(groovy.json.JsonOutput.prettyPrint(jsonGenerator.toJson(it)))}

// referencesOnly
//   // .map { [it[0], it[1][0]]} //meta, fasta_file
//   // .view()
//   .map { meta, files ->
//     // meta.seqtype = meta.seqtype[0] //un-list
//     // files.sort { a,b -> a.name.substring(a.name.lastIndexOf('.')+1) <=> b.name.substring(b.name.lastIndexOf('.')+1) } //ensure gff goes after fasta based on extension
//     [meta, files[0]] //meta, fasta_file
//   }
//   // .view()
//   .into {referencesForAligners; references4rnfSimReads}


process extractTranscripts {
  echo true
  label 'gffread'
  label 'slow'
  tag{meta.subMap(['species','version'])}
  scratch false

  //SLOW? add fasta fai

  input:
    // set val(meta), file(ref), file(features) from referencesForTranscriptomeExtraction
    set val(meta), file(ref), file(fai), file(features) from referencesForTranscriptomeExtraction
                    // .filter { it[1].size() == 2 } //2 files needed aka skip if fasta-only
                    // .map { meta, files ->
                    //   // files.sort { a,b -> a.name.substring(a.name.lastIndexOf('.')+1) <=> b.name.substring(b.name.lastIndexOf('.')+1) } //ensure gff goes after fasta
                    //   [meta, files[0], files[1]] }
  output:
    set val(outmeta), file(outfile) into extractedTranscriptomes //transcripts4indexing, transcripts4rnfSimReads

  when:
    'rna2rna'.matches(params.mapmode) || 'rna2dna'.matches(params.mapmode)

  shell:
    // println(prettyPrint(toJson(meta)))
    basename=getTagFromMeta(meta)
    outmeta = meta.subMap(['species','version']) //meta.clone()
    outmeta.seqtype = 'RNA'
    outfile = "${basename}.transcripts.fa"
    // println(prettyPrint(toJson(outmeta)))
    // FEATURE_FIELD = meta.featfmt == 'bed' ? 8 : 3 //BED OR GFF3
    // '''
    // gffread --merge -W -w !{outfile} -g !{ref} !{features}
    // '''
    //set -eo pipefail
    '''
    gffread -W -w- -g !{ref} !{features} \
      | awk '/^>/ { if(NR>1) print "";  printf("%s\\t",$0); next; } { printf("%s",$0);} END {printf("\\n");}' \
      | tee tmp.fa \
      | awk 'NR==FNR{all[$1]+=1}; NR!=FNR{if(all[$1]==1){print}}' - tmp.fa  \
      | tr '\\t' '\\n' \
      > !{outfile} && rm tmp.fa
    '''
    // #-w- AND | awk '/^>/ { if(NR>1) print "";  printf("%s\\t",$0); next; } { printf("%s",$0);} END {printf("\\n");}' \
    // #| sort -k1,1V | tr '\\t' '\\n' > !{outfile}
    // '''
    //     #awk '/^>/ { if(NR>1) print "";  printf("%s\\n",$0); next; } { printf("%s",$0);} END {printf("\\n");}' tmp \
    // #| paste - - | sort -k1,1V | tr '\\t' '\\n' > !{outfile}
}

process faidxTranscriptomeFASTA {
  tag("${refmeta}")
  label 'samtools'

  input:
    set val(refmeta), file(fa) from extractedTranscriptomes

  output:
    set val(refmeta), file(fa), file("${fa}.fai") into transcriptomesForIndexing, transcriptomesForRnfSimReads

  script:
  """
  samtools faidx ${fa}
  """
}

/*
Resolve variables emebeded in single-quoted strings
*/
def String resolveScriptVariables(String template, Map binding) {
  def engine = new groovy.text.SimpleTemplateEngine()
  engine.createTemplate(template).make(binding).toString()
}

mappersIdxChannel.combine(genomesForIndexing.mix(transcriptomesForIndexing))
.filter { mapper, refmeta, ref, fai->
  [['RNA','rna2rna'],['DNA','rna2dna'],['DNA','dna2dna']].any { refmeta.seqtype == it[0] && mapper.containsKey(it[1]) && it[1].matches(params.mapmode) }
}
// .view{ it -> groovy.json.JsonOutput.prettyPrint(jsonGenerator.toJson(it))}
.map { mapper, refmeta, ref, fai ->
  [
    mapper.subMap(allRequired)+[idxTemplate: ('index' in mapper.templates) ], //second part shuld have been done at validation
    refmeta,
    ref,
    fai
  ]
} //Exclude mapping specific fields from indexing process to avoid re-indexing e.g. on changes made to a mapping template
// .view{ it -> groovy.json.JsonOutput.prettyPrint(jsonGenerator.toJson(it))}
.set { forIndexing }

process indexGenerator {
  label 'index'
  container { "${mapper.container}" }
  // tag("${alignermeta.tool} << ${refmeta}")
  tag { [refmeta.subMap(['species','version','seqtype']), mapper.subMap(['tool','version'])] }

  input:
    // set val(alignermeta), val(refmeta), file(ref), file(fai) from aligners.combine(genomesForIndexing.mix(transcriptomesForIndexing))
    // set val(mapper), val(refmeta), file(ref), file(fai) from mappersIdxChannel.combine(genomesForIndexing.mix(transcriptomesForIndexing))
    set val(mapper), val(refmeta), file(ref), file(fai) from forIndexing

  output:
    set val(idxmeta), file(ref), file(fai), file("*") into indices

  // when: //check if reference intended for {D,R}NA alignment reference and tool has a template declared for that purpose which is also included in mapmode
  //   [['RNA','rna2rna'],['DNA','rna2dna'],['DNA','dna2dna']].any { refmeta.seqtype == it[0] && mapper.containsKey(it[1]) && it[1].matches(params.mapmode) }

  exec:
    //meta = [toolmodes: alignermeta.modes, tool: "${alignermeta.tool}", target: "${ref}"]+refmeta.subMap(['species','version','seqtype'])
    // meta = [mapper: mapper, target: refmeta+[file: ref]]
    // println(groovy.json.JsonOutput.prettyPrint(jsonGenerator.toJson(mapper+refmeta+[ref: ref])))
    def binding = [ref: "${ref.name}", task: task.clone()]
    idxmeta = [mapper: mapper.subMap(['tool','version']), reference: refmeta]
  script:
    if(mapper.idxTemplate == true) { //Indexing template file declared
      template mapper.index == true ? "index/${mapper.tool}.sh" : "index/${mapper.index}" //either default or explicit template file name
    } else { //indexing script string embeded in config
      resolveScriptVariables(mapper.index, binding)
    }
}

process rnfSimReads {
  // echo true
  tag{simmeta}
  label 'rnftools'
  label 'slow'

  input:
    // set val(meta), file(ref), file(fai) from referencesWithIndex4rnfSimReads
    set val(meta), file(ref), file(fai) from genomesForRnfSimReads.mix(transcriptomesForRnfSimReads)
    // set val(meta), file(ref) from transcripts4rnfSimReads
    // each nsimreads from params.simreadsDNA.nreads.toString().tokenize(",")*.toInteger()
    each coverage from params.simreadsDNA.coverage
    each length from params.simreadsDNA.length.toString().tokenize(",")*.toInteger()
    each simulator from params.simreadsDNA.simulator
    each mode from params.simreadsDNA.mode //PE, SE
    each distance from params.simreadsDNA.distance //PE only
    each distanceDev from params.simreadsDNA.distanceDev //PE only

  output:
    // set val(simmeta), file("*.fq.gz") into readsForAlignment
    // set val(simmeta), file(ref), file("*.fq.gz") into readsForCoordinateConversion
    set val(simmeta), file(ref), file(simStats), file("*.fq.gz") into simulatedReads


  when:
    !(mode == "PE" && simulator == "CuReSim") && \
    (meta.seqtype == 'RNA' || (meta.seqtype == 'DNA' && 'dna2dna'.matches(params.mapmode) ))
    // ((meta.seqtype == 'mRNA' && 'rna2rna'.matches(params.alnmode)) || (meta.seqtype == 'DNA' && 'rna2rna'.matches(params.alnmode))


  // exec:
  //   println(prettyPrint(toJson(meta)))

  script:
    basename=meta.species+"_"+meta.version+"_"+simulator
    simmeta = meta.subMap(['species','version','seqtype'])+["simulator": simulator, "coverage":coverage, "mode": mode, "length": length, 'coordinates': meta.seqtype]
    len1 = length
    if(mode == "PE") {
      //FOR rnftools
      len2 = length
      tuple = 2
      dist="distance="+distance+","
      distDev= "distance_deviation="+distanceDev+","
      //FOR meta
      simmeta.dist = distance
      simmeta.distanceDev = distanceDev
    } else {
      len2 = 0
      tuple = 1
      dist=""
      distDev=""
    }
    """
    echo "import rnftools
    rnftools.mishmash.sample(\\"${basename}_reads\\",reads_in_tuple=${tuple})
    rnftools.mishmash.${simulator}(
            fasta=\\"${ref}\\",
            coverage=${coverage},
            ${dist}
            ${distDev}
            read_length_1=${len1},
            read_length_2=${len2}
    )
    include: rnftools.include()
    rule: input: rnftools.input()
    " > Snakefile
    snakemake -p \
    && paste --delimiters '=' <(echo -n nreads) <(sed -n '1~4p' *.fq | wc -l) > simStats \
    && time sed -i '2~4 s/[^ACGTUacgtu]/N/g' *.fq \
    && time gzip --fast *.fq \
    && find . -type d -mindepth 2 | xargs rm -r
    """
}

//extract simulation stats from file (currently number of reads only), reshape and split to different channels
// readsForCoordinateConversion = Channel.create()
simulatedReads.map { simmeta, ref, simStats, simReads ->
    // simStats.splitEachLine("=", { record ->
    //   if(record.size() > 1) {
    //     v = record[1]
    //     simmeta."${record[0]}" = v.isInteger() ? v.toInteger() : v.isDouble() ? v.toDouble() : v
    //   }
    // })
    parseFileMap(simStats, simmeta)
    new Tuple(simmeta, ref, simReads)
  }
  .tap { readsForCoordinateConversion }
  .map { simmeta, ref, simReads  ->
    new Tuple(simmeta, simReads)
  }
  // .view { it -> println(groovy.json.JsonOutput.prettyPrint(jsonGenerator.toJson(it))) }
  .set{ readsForAlignment }




// // process simStats{
// //   input:
// //     set val(simmeta), file(reads) from readsForSimStats

// //   output:
// //     set val(simmeta), stdout(count) into simCounts

// //   """
// //   zcat ${reads[0]} | sed -n '1~4p' | wc -l
// //   """
// // }

process convertReadCoordinates {
  label 'groovy'
  echo true
  tag{simmeta.subMap(['species','version'])}


  input:
    set val(simmeta), file(ref), file(reads), val(refmeta), file(fai) from readsForCoordinateConversion.combine(genomeIndicesForReadCoordinateConversion)

  output:
    set val(outmeta), file('*.fq.gz') into convertedCoordinatesReads

  when:
    simmeta.seqtype == 'RNA' && 'rna2dna'.matches(params.mapmode) \
    && simmeta.species == refmeta.species && simmeta.version == refmeta.version

  // exec:
  //   println(prettyPrint(toJson(simmeta)))
  //   println(prettyPrint(toJson(refmeta)))

  script:
  out1 = reads[0].name.replace('.1.fq.gz','.R1.fq.gz')
  out2 = reads[1].name.replace('.2.fq.gz','.R2.fq.gz')
  outmeta = [:]
  outmeta.putAll(simmeta)
  outmeta.remove('coordiantes')
  outmeta.coordinates = 'DNA'
  """
  tct_rnf.groovy \
    --genome-index ${fai} \
    --transcriptome ${ref} \
    --in-forward ${reads[0]} --in-reverse ${reads[1]} \
    --out-forward ${out1} --out-reverse ${out2}
  """
}

// // // convertedCoordinatesReads.view()

// // // convertedCoordinatesReads.mix(readsForAlignment).combine(indices).combine(alignersParams).view { it -> println(groovy.json.JsonOutput.prettyPrint(jsonGenerator.toJson(it)))}

// mappersMapChannel  .view { it -> groovy.json.JsonOutput.prettyPrint(jsonGenerator.toJson(it))}

/*
 This is where we combine
*/
convertedCoordinatesReads.mix(readsForAlignment)
.combine(indices)
.filter { simmeta, reads, idxmeta, ref, fai, idx ->
  //reads - reference species & version check
  idxmeta.reference.species == simmeta.species && idxmeta.reference.version == simmeta.version
}
.combine(mappersMapChannel)
.combine(mappersParamsChannel)
.filter { simmeta, reads, idxmeta, ref, fai, idx, mapper, paramsmeta -> //tool & version check
  [mapper.tool, idxmeta.mapper.tool].every { it == paramsmeta.tool }  \
  && mapper.version == idxmeta.mapper.version \
  && mapper.version in paramsmeta.version
}
.combine(mapModesChannel)
.filter { simmeta, reads, idxmeta, ref, fai, idx, mapper, paramsmeta, mode ->  //map mode check
  mapper.containsKey(mode) && mode.matches(paramsmeta.mode) \
  && mode.startsWith(simmeta.seqtype.toLowerCase()) \
  && [simmeta.coordinates, idxmeta.reference.seqtype].every { mode.endsWith( it.toLowerCase() ) }
}
// .view{ groovy.json.JsonOutput.prettyPrint(jsonGenerator.toJson(it))}
.map { simmeta, reads, idxmeta, ref, fai, idx, mapper, paramsmeta, mode ->
  def template = (mode in mapper.templates) ? (mapper."${mode}" == true ? "${mode}/${mapper.tool}.sh" : "${mode}/${mapper.${mode}}") : false;
  [
    [mapper: mapper.subMap(['tool','version','container']), query: simmeta, target: idxmeta.reference, params: paramsmeta.subMap(['label','params'])],
    reads, //as is
    ref, fai, idx, //as is
    [template: template, script: (template ? false: mapper."${mode}")],
    paramsmeta.params
  ]
}
// .view{ groovy.json.JsonOutput.prettyPrint(jsonGenerator.toJson(it))}
// .count()
.set{ combinedToMap }


// .view{ groovy.json.JsonOutput.prettyPrint(jsonGenerator.toJson(it))}

process mapSimulatedReads {
  label 'align'
  container { "${meta.mapper.container}" }
  tag {"${meta.target.seqtype}@${meta.target.species}@${meta.target.version} << ${meta.query.nreads}@${meta.query.seqtype}; ${meta.mapper.tool}@${meta.mapper.version}@${meta.params.label}"}

  input:
    set val(meta), file(reads), file(ref), file(fai), file('*'), val(run), val(ALIGN_PARAMS) from combinedToMap

  output:
    set val(meta), file(ref), file(fai), file('*.?am'), file('.command.trace') into alignedSimulated

  script:
    def binding = [ref: ref, reads: reads, task: task.clone(), ALIGN_PARAMS: ALIGN_PARAMS]
    if(run.template) { //if template file specified / declared
      template run.template //either default or explicit template file name
    } else { //indexing script defined in config
      resolveScriptVariables(run.script, binding)
    }
}

process evaluateAlignmentsRNF {
  label 'samtools'
  // label 'ES'
  // tag{alignmeta.tool.subMap(['name'])+alignmeta.target.subMap(['species','version'])+alignmeta.query.subMap(['seqtype','nreads'])+alignmeta.params.subMap(['paramslabel'])}
  // tag{alignmeta.params.subMap(['paramslabel'])}
  // tag{alignmeta.subMap(['tool','simulator','target.species','alignMode','paramslabel'])}
  tag {"${meta.target.seqtype}@${meta.target.species}@${meta.target.version} << ${meta.query.nreads}@${meta.query.seqtype}; ${meta.mapper.tool}@${meta.mapper.version}@${meta.params.label}"}

  input:
    set val(meta), file(ref), file(fai), file(samOrBam) from alignedSimulated.map { mapmeta, ref, fai, samOrBam, trace ->
        def traceMap = [:]
        parseFileMap(trace, traceMap) //could be parseFileMap(trace, meta.trace, 'realtime') or parseFileMap(trace, meta, ['realtime','..']) or parseFileMap(trace, meta) to capture all fields
        [mapmeta+[trace: traceMap], ref, fai, samOrBam]
      }

  output:
     set val(meta), file ('*.json') into evaluatedAlignmentsRNF
    //  set val(alignmeta), file('ES.gz'),  into esChannel  //add to script: --es-output ES.gz

  // exec:
  script:
  // println prettyPrint(toJson(alignmeta))
  // println alignmeta.inspect()

  """
  set -eo pipefail
  samtools view ${samOrBam} \
  | eval_rnf.groovy \
      --allowed-delta ${params.allowedDelta} \
      --faidx ${fai} \
      --output summary.json \
  """
}


/**
1. Embed evaluation results JSON in META JSON.
2. Collect all datapoints in one JSON for output.
**/
def slurper = new groovy.json.JsonSlurper()
evaluatedAlignmentsRNF.map { META, JSON ->
      [META+[evaluation: slurper.parseText(JSON.text)]]
  }
  .collect()
  .map {
    file("${params.outdir}").mkdirs()
    outfile = file("${params.outdir}/allstats.json")
    // outfile.text = groovy.json.JsonOutput.prettyPrint(jsonGenerator.toJson(it))
    outfile.text = groovy.json.JsonOutput.prettyPrint(jsonGenerator.toJson(it.sort( {k1,k2 -> k1.mapper.tool <=>  k2.mapper.tool} ) ))
  }


// // process plotSummarySimulated {
// //   label 'rscript'
// //   label 'figures'

// //   input:
// //     // set file(csv), file(json) from collatedSummariesSimulatedDNA
// //     set file(json), file(categories) from collatedSummariesSimulated

// //   output:
// //     file '*' into collatedSummariesPlotsSimulated

// //   shell:
// //   '''
// //   < !{json} plot_simulatedDNA.R
// //   '''
// // }



// // process plotSummarySimulated {
// //   label 'rscript'
// //   label 'figures'

// //   input:
// //     // set file(csv), file(json) from collatedSummariesSimulatedDNA
// //     set file(json), file(categories) from collatedSummariesSimulatedDNA

// //   output:
// //     file '*' into collatedSummariesPlotsSimulated

// //   shell:
// //   '''
// //   < !{json} plot_simulatedDNA.R
// //   '''
// // }

// // //WRAP-UP
// // writing = Channel.fromPath("$baseDir/report/*").mix(Channel.fromPath("$baseDir/manuscript/*")) //manuscript dir exists only on manuscript branch

// // process render {
// //   tag {"Render ${Rmd}"}
// //   label 'rrender'
// //   label 'report'
// //   stageInMode 'copy'
// //   //scratch = true //hack, otherwise -profile singularity (with automounts) fails with FATAL:   container creation failed: unabled to {task.workDir} to mount list: destination ${task.workDir} is already in the mount point list

// //   input:
// //     // file('*') from plots.flatten().toList()
// //     // file('*') from plotsRealRNA.flatten().toList()
// //     file(Rmd) from writing
// //     file('*') from collatedDetailsPlotsSimulatedDNA.collect()
// //     file('*') from collatedSummariesPlotsSimulatedDNA.collect()

// //   output:
// //     file '*'

// //   script:
// //   """
// //   #!/usr/bin/env Rscript

// //   library(rmarkdown)
// //   library(rticles)
// //   library(bookdown)

// //   rmarkdown::render("${Rmd}")
// //   """
// // }
// // }

// // //WRAP-UP
// // writing = Channel.fromPath("$baseDir/report/*").mix(Channel.fromPath("$baseDir/manuscript/*")) //manuscript dir exists only on manuscript branch

// // process render {
// //   tag {"Render ${Rmd}"}
// //   label 'rrender'
// //   label 'report'
// //   stageInMode 'copy'
// //   //scratch = true //hack, otherwise -profile singularity (with automounts) fails with FATAL:   container creation failed: unabled to {task.workDir} to mount list: destination ${task.workDir} is already in the mount point list

// //   input:
// //     // file('*') from plots.flatten().toList()
// //     // file('*') from plotsRealRNA.flatten().toList()
// //     file(Rmd) from writing
// //     file('*') from collatedDetailsPlotsSimulatedDNA.collect()
// //     file('*') from collatedSummariesPlotsSimulatedDNA.collect()

// //   output:
// //     file '*'

// //   script:
// //   """
// //   #!/usr/bin/env Rscript

// //   library(rmarkdown)
// //   library(rticles)
// //   library(bookdown)

// //   rmarkdown::render("${Rmd}")
// //   """
// // }
