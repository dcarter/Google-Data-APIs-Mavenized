#!/usr/bin/ruby -w

require 'pp';
require 'set';
require 'tmpdir'

# maven command lines
$Mvn_deploy_snapshot = 'mvn -e deploy:deploy-file'
$Mvn_deploy_release  = 'mvn -e gpg:sign-and-deploy-file'

# maven coordinates
$Group = 'com.github.dcarter.gdata-java-client'
$Release_repo = 'sonatype-nexus-staging' 
$Release_repo_url = 'http://oss.sonatype.org/service/local/staging/deploy/maven2'
$Snapshot_repo = 'sonatype-nexus-snapshots' 
$Snapshot_repo_url = 'http://oss.sonatype.org/content/repositories/snapshots'

def get_tattletale(dest=Dir.tmpdir, version='1.1.0.Final') 
  
  tattletale_basename = "jboss-tattletale-#{version}"
  tattletale_archive = "#{tattletale_basename}.tar.gz"
  tattletale_url = "http://sourceforge.net/projects/jboss/files/JBoss%20Tattletale/#{version}/#{tattletale_archive}/download"
  tattletale_destfile = File.join(dest,tattletale_archive)
  tattletale_destdir = File.join(dest,tattletale_basename)
  tattletale = File.join(tattletale_destdir,'tattletale.jar')

  # tattletale is cached; if you want to re-download a given version, you must delete prev files
  if !File.exists?(tattletale) then
    puts "Downloading tattletale"  
    `wget -nc #{tattletale_url} -O #{tattletale_destfile}`
    `cd #{dest} && tar -xzf #{tattletale_destfile}`
    FileUtils.rm(tattletale_destfile)
  end
  
  return tattletale
end

def get_gdata_jars(version, dest=Dir.tmpdir)

  basename = "gdata-src.java-#{version}" 
  archive = "#{basename}.zip"
  destfile = File.join(dest,archive) 
  destdir = File.join(dest,basename) 
  uri = "http://gdata-java-client.googlecode.com/files/#{archive}" 
  libs = File.join(destdir,"gdata","java","lib")
  deps = File.join(destdir,"gdata","java","deps",".")

  # gdata jars are cached; if you want to re-download a given version, you must delete prev files
  if !(File.exists?(libs) && File.directory?(libs)) then  
    puts "Downloading #{archive}"  
    `wget -nc #{uri} -O #{destfile}`
    `unzip #{destfile} -d #{destdir}`
    FileUtils.rm(destfile)
    FileUtils.cp_r(deps,libs)
  end
  
  return libs
end

def find_dependencies(version, jarpath, dest=Dir.tmpdir)

  # run the jboss tattletale dependency analyzer, output into temp dir, pluck out the .dot file of dependencies
  outdir = File.join(dest, "tattletale_out", "gdata-#{version}")
  dotfile = File.join(outdir,"graphviz","dependencies.dot")

  # tattletale results are cached; if you want to rebuild, you must delete prev files
  if !File.exists?(dotfile) then      
    puts "Running tattletale. . ."
    `java -Xmx512m -jar #{$Tattletale}  #{jarpath} #{outdir}`
  end

  # parse dependencies .dot file & output pom.xml files for each jar
  #          and a script file to do the mvn deploy:deploy-file for each jar/pom combo
  #   the gdata distribution version becomes the <version></version> value in the pom
  #   the artifact id is the jar basename including version, as shipped from google, e.g. 'gdata-calendar-2.0'
  #   group id will use our own groupId, since we can't release under com.google groupId

  depends_txt = File.read(dotfile)

  depends = depends_txt.gsub(/;/,'').gsub(/_/,'-').gsub(/(\D+-\d+)-(\d+)/,'\1.\2').scan(/(\S+)\s+->\s+(\S+)/);
  
  # build hash of dependencies - content of each hash entry is an array of the depended-upon jars
  depends_hash = Hash.new();
  depends.inject(depends_hash) { |hash, dependency|  
    if hash[dependency[0]] then
      hash[dependency[0]].push(dependency[1])
    else 
      hash[dependency[0]] = Array.new([dependency[1]])
    end
    hash;
  }

  # determine which dependencies are terminal dependencies
  terminal_deps =  depends_hash.inject(Set.new) { |set, a| set.merge([*a.flatten()] ) } # gives set of all artifacts that are depended on
  terminal_deps.subtract(depends_hash.keys)                                             # remove those that have dependencies
  # tattletale can't tell us which jars rely on the jsr305 jar that is shipped in deps, so we will assume they all do

  terminal_deps.each {|dep|
    # add an "empty" dependency entry for each terminal dependency
    # unless it is the google collections jar, which already exist on maven central, so we don't want to upload another
    depends_hash[dep] = nil unless dep =~ /^google-collect-/
  }
  return depends_hash
end 

def generate_poms(version, dependencies, jarpath, dest=Dir.tmpdir, snapshot=FALSE)

  outdir = File.join(dest, snapshot ? "snapshot" : "release", "v#{version}")
  
  FileUtils.rm_r(outdir)  if File.exists?(outdir)    # start clean each time, so we have no orphan pom if a jar is deleted
  FileUtils.mkdir(outdir)
  
  pom_version = version + (snapshot ? '-SNAPSHOT' : '')
  
  puts "Generating poms to #{outdir}"
  
  script_file_name = File.join(outdir,"mvn_deploy_gdata_#{version}")
  script_file = File.new(script_file_name, "w")
  
  script_file.puts "#!/bin/bash\n\n"
  script_file.puts "MVN='#{snapshot ? $Mvn_deploy_snapshot : $Mvn_deploy_release}'"
  script_file.puts "JARS='#{File.join(jarpath,'/')}'"
  script_file.puts "POMS='#{File.join('.','/')}'"
  script_file.puts "REPO='#{snapshot ? $Snapshot_repo : $Release_repo}'"
  script_file.puts "URL='#{snapshot ? $Snapshot_repo_url : $Release_repo_url}'\n\n"

  dependencies.keys.sort.each { |key|  
    pom_file_name = key + "-pom.xml"
    pom_file = File.new(File.join(outdir,pom_file_name), "w")

    pom_file.puts '<?xml version="1.0" encoding="UTF-8"?>'
    pom_file.puts '<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/maven-v4_0_0.xsd">'
    pom_file.puts "  <modelVersion>4.0.0</modelVersion>"
    pom_file.puts "  <groupId>#{$Group}</groupId>"
    pom_file.puts "  <artifactId>#{key}</artifactId>"
    pom_file.puts "  <version>#{pom_version}</version>"
    pom_file.puts "  <name>#{key}</name>"
    pom_file.puts "  <description>3rd-party jar #{key} from gdata-java-client project repackaged to meet requirements of Maven central repo</description>"    
    pom_file.puts "  <url>http://code.google.com/p/gdata-java-client/</url>" 
    pom_file.puts "  <licenses>"
    pom_file.puts "    <license>"
    pom_file.puts "      <name>Apache 2</name>"
    pom_file.puts "      <url>http://www.apache.org/licenses/LICENSE-2.0.txt</url>"
    pom_file.puts "    </license>"
    pom_file.puts "  </licenses>"
    pom_file.puts "  <scm>"
    pom_file.puts "    <url>http://code.google.com/p/gdata-java-client/source/browse/</url>"
    pom_file.puts "  </scm>"
    pom_file.puts "  <developers>"
    pom_file.puts "    <developer>"
    pom_file.puts "      <id>gdata-team</id>"
    pom_file.puts "      <name>The Google GData Team</name>"
    pom_file.puts "      <url>http://code.google.com/p/gdata-java-client/people/list</url>"
    pom_file.puts "      <organization>Google</organization>"
    pom_file.puts "    </developer>"
    pom_file.puts "  </developers>"
    if dependencies[key] then
      pom_file.puts "  <dependencies>"
      dependencies[key].uniq.sort.each { |dep| 
        # if the dependency is on google collections, need to use the proper group/artifact/version
        # TODO: move this to find_dependencies phase. will require expanding the dependencies data structure to include group & version
        #       in addition to artifactId 
        if dep =~ /google-collect-(\S+)/   then    # e.g. - google-collect-1.0-rc1
          dep_group = 'com.google.collections'
          dep_artifact = 'google-collections'
          dep_version = $1
        else
          dep_group = $Group
          dep_artifact = dep
          dep_version = pom_version
        end
        pom_file.puts "    <dependency>"
        pom_file.puts "      <groupId>#{dep_group}</groupId>"
        pom_file.puts "      <artifactId>#{dep_artifact}</artifactId>"
        pom_file.puts "      <version>#{dep_version}</version>"
        pom_file.puts "    </dependency>"
      }
      pom_file.puts "  </dependencies>"
    end
    pom_file.puts "</project>"
    pom_file.close;
    script_file.puts "${MVN} -Dfile=${JARS}#{key}.jar -DpomFile=${POMS}#{pom_file_name} -DrepositoryId=${REPO} -Durl=${URL}"
  }
  script_file.close
  FileUtils.chmod(0744,script_file_name)
  return outdir
end

# execution begins here

tempdir = File.join(Dir.tmpdir,"gdata-mvn")
FileUtils.mkdir(tempdir) unless File.exists?(tempdir) && File.directory?(tempdir)

outdir = File.join(FileUtils.pwd(),"target")
FileUtils.mkdir(outdir) unless File.exists?(outdir) && File.directory?(outdir)

$Tattletale = get_tattletale(tempdir)

['1.40.0', '1.40.1', '1.40.2', '1.40.3', '1.41.0', '1.41.1'].each { |version|
  
  jarpath = get_gdata_jars(version, tempdir)

  deps = find_dependencies(version, jarpath, tempdir)

  # generate snapshot poms  
  snaps_location = generate_poms(version, deps, jarpath, outdir, TRUE)
    
  # generate release poms
  rel_location   = generate_poms(version, deps, jarpath, outdir, FALSE)
  
  puts "Snapshot poms & deployment script created in #{snaps_location}\n\n"
  puts " Release poms & deployment script created in #{rel_location}\n\n"
}





