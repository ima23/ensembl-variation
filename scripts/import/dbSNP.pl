# this is the experimental script to fill the new variation 
# schema with data from dbSNP
# we use the local mysql copy of dbSNP at the sanger center

use strict;
use DBI;

my $tmp_dir = "/ecs2/scratch5/ensembl/mcvicker/dbSNP";

my $dbSNP = DBI->connect( "DBI:mysql:host=cbi2.internal.sanger.ac.uk;dbname=dbSNP_120", "dbsnpro" );

my $dbVar = DBI->connect( "DBI:mysql:host=ecs4.internal.sanger.ac.uk;dbname=mcvicker_variation;port=3352","ensadmin", "ensembl" );

my $dbCore = DBI->connect( "DBI:mysql:host=ecs2.internal.sanger.ac.uk;dbname=homo_sapiens_core_22_34d;port=3364","ensro" );


my $TAX_ID = 9606; # human

my $LIMIT = '';
#my $LIMIT = ' LIMIT 100000';


population_table();
source_table();
variation_table();
individual_genotypes();
population_genotypes();
allele_table();
flanking_sequence_table();
variation_feature();
variation_group();
allele_group();

cleanup();


sub source_table {
  $dbVar->do(qq(INSERT INTO source SET source_id = 1, name = "dbSNP"));
}


# filling of the variation table from SubSNP and SNP
# creating of a link table variation_id --> subsnp_id
sub variation_table {
  $dbVar->do( "ALTER TABLE variation add column snp_id int" );
  $dbVar->do( "ALTER TABLE variation add column subsnp_id int" );

  # load refSNPs into the variation table

  debug("Dumping RefSNPs");

  dumpSQL( qq{
           SELECT 1, concat( "rs", snp_id), snp_id
           FROM SNP
           WHERE tax_id = $TAX_ID
           $LIMIT
          }
      );

  debug("Loading RefSNPs into variation table");

  load( "variation", "source_id", "name", "snp_id" );

  $dbVar->do( "ALTER TABLE variation ADD INDEX snpidx( snp_id )" );

  # create a temp table of subSNP info
  # containing RefSNP id, SubSNP id and validation status

  debug("Dumping SubSNPs");

  dump_subSNPs();

  create_and_load( "tmp_var_allele", "subsnp_id", "refsnp_id", "pop_id",
                   "allele","valid", "substrand_reversed_flag");

  $dbVar->do( qq{
                 ALTER TABLE tmp_var_allele MODIFY subsnp_id int
                } );
  $dbVar->do( qq{
                 ALTER TABLE tmp_var_allele add INDEX subsnp_idx( subsnp_id )
                } );

  debug("Building SubSNP parent ids");

  # create a second temp table containing the parent_id of the subsnps
  $dbVar->do( qq{
                 CREATE TABLE tmp_var2
                 SELECT tv.subsnp_id, v.variation_id, tv.valid,
                        tv.substrand_reversed_flag
                 FROM tmp_var_allele tv, variation v
                 WHERE tv.refsnp_id = v.snp_id
                 GROUP BY tv.subsnp_id
                });

  debug("Loading SubSNPs into variation table");
  # load the SubSNPs into the variation table


  $dbVar->do(qq{ALTER TABLE variation ADD COLUMN substrand_reversed_flag tinyint});

  $dbVar->do( qq{
                 INSERT INTO variation( source_id, name, parent_variation_id,
                                  validation_status, subsnp_id, substrand_reversed_flag)
                 SELECT 1, concat("ss",subsnp_id), variation_id,
                        valid, subsnp_id, substrand_reversed_flag
                 FROM tmp_var2
                } );

  $dbVar->do('DROP table tmp_var2');

  # set the validation status of the RefSNPs.  A refSNP is validated if
  # it has a valid subsnp

  debug("Reloading RefSNPs with validation status set");

  my $sth = $dbVar->prepare
    (qq{SELECT a.variation_id, a.source_id, a.name, a.snp_id,
               b.validation_status
        FROM   variation a, variation b
        WHERE  b.parent_variation_id = a.variation_id
        ORDER BY a.variation_id, b.validation_status});

  $sth->execute();

  my $cur_variation_id = undef;
  my $validated = 0;
  my $arr;

  # dump RefSNPs to tmp file with validation status set

  open ( FH, ">$tmp_dir/tabledump.txt" );

  while($arr = $sth->fetchrow_arrayref()) {
    if(defined($cur_variation_id) && $arr->[0] != $cur_variation_id) {
      my @arr = map {(defined($_)) ? $_ : '\N' } @$arr;
      print FH join("\t", @arr), "\n";
    }
    $cur_variation_id = $arr->[0];
  }

  close(FH);

  # remove RefSNPs from db and reload them (faster than individual updates)

  $dbVar->do("DELETE FROM variation WHERE parent_variation_id is NULL");

  load("variation", "variation_id", "source_id",
       "name", "snp_id", "validation_status");

  $dbVar->do("ALTER TABLE variation ADD INDEX subsnp_id(subsnp_id)");

  return;
}


#
# dumps subSNPs and associated allele information
#
sub dump_subSNPs {

  my $sth = $dbSNP->prepare
    (qq{SELECT subsnp.subsnp_id, subsnplink.snp_id, b.pop_id, ov.pattern,
             if ( subsnp.validation_status > 0, "VALIDATED", "NOT_VALIDATED" ),
             subsnplink.substrand_reversed_flag
        FROM SubSNP subsnp, SNPSubSNPLink subsnplink, ObsVariation ov
        LEFT JOIN Batch b on subsnp.batch_id = b.batch_id
        WHERE subsnp.subsnp_id = subsnplink.subsnp_id
        AND   ov.var_id = subsnp.variation_id
        $LIMIT
       } );

  $sth->execute();

  open ( FH, ">$tmp_dir/tabledump.txt" );

  my $row;
  while($row = $sth->fetchrow_arrayref()) {
    my @alleles = split('/', $row->[3]);

    my @row = map {(defined($_)) ? $_ : '\N'} @$row;

    # split alleles into multiple rows
    foreach my $a (@alleles) {
      $row[3] = $a;
      print FH join("\t", @row), "\n";
    }
  }

  $sth->finish();

  close FH;
}


#
# loads the population table
#
sub population_table {

  $dbVar->do("ALTER TABLE population ADD column pop_id int");
  $dbVar->do("ALTER TABLE population ADD column pop_class_id int");

  # load PopClassCode data into tmp table

  debug("Dumping population class data");

  dumpSQL("SELECT pop_class, pop_class_id, pop_class_text FROM PopClassCode");

  debug("Loading population class data");

  create_and_load( "tmp_pop_class", "name", "pop_class_id", "description");

  $dbVar->do("ALTER TABLE tmp_pop_class MODIFY pop_class_id int");
  $dbVar->do(qq{ALTER TABLE tmp_pop_class 
                ADD INDEX pop_class_id (pop_class_id)});

  debug("Dumping population data");

  # load Population data into tmp table

  ### TBD should a parent population of UNKNOWN be created for populations without
  ### a PopClass?

  dumpSQL(qq{SELECT concat(p.handle, ':', p.loc_pop_id),
                    p.pop_id, pc.pop_class_id
             FROM   Population p
             LEFT JOIN PopClass pc ON p.pop_id = pc.pop_id});

  debug("Loading population data");

  create_and_load( "tmp_pop", "name", "pop_id", "pop_class_id" );

  # create a table containing a count of the popclasses that the populations have

  $dbVar->do(qq{CREATE TABLE tmp_pop_count
                SELECT tp.pop_id AS pop_id, COUNT(*) AS count
                FROM   tmp_pop tp
                WHERE  tp.pop_class_id IS NOT NULL
                GROUP BY tp.pop_id});

  # pops without a popclass get a count of 0
  $dbVar->do(qq{INSERT INTO tmp_pop_count (pop_id, count)
                SELECT tp.pop_id, 0
                FROM   tmp_pop tp
                WHERE  tp.pop_class_id IS NULL});

  $dbVar->do("ALTER TABLE tmp_pop MODIFY pop_class_id int");
  $dbVar->do("ALTER TABLE tmp_pop ADD INDEX pop_class_id(pop_class_id)");
  $dbVar->do("ALTER TABLE tmp_pop MODIFY pop_id int");
  $dbVar->do("ALTER TABLE tmp_pop ADD INDEX pop_id(pop_id)");
  $dbVar->do("ALTER TABLE tmp_pop_count ADD INDEX pop_id(pop_id)");
  $dbVar->do("ALTER TABLE tmp_pop_count ADD INDEX count_idx(count)");

  debug("Creating population table");

  # load PopClasses as parent populations
  $dbVar->do(qq{INSERT INTO population (name, pop_class_id, description,
                                        population_type)
                SELECT name, pop_class_id, description, 'general'
                FROM   tmp_pop_class});

  # set the parent pop_id of the other populations,
  # take only populations with 0 or 1 parent

  $dbVar->do(qq(CREATE table tmp_pop2
                SELECT tp.name as name, tp.pop_id as pop_id,
                       p.population_id as parent_population_id
                FROM   tmp_pop tp, tmp_pop_count tpc
                LEFT JOIN population p ON p.pop_class_id = tp.pop_class_id
                WHERE    tp.pop_id = tpc.pop_id
                AND    tpc.count < 2));

  $dbVar->do(qq{INSERT INTO population (name, parent_population_id, pop_id,
                                        population_type)
                SELECT name, parent_population_id, pop_id, 'general'
                FROM   tmp_pop2});

  # take all populations with multiple parent classes
  # and name them MULTI-NATIONAL

  $dbVar->do("DROP TABLE tmp_pop2");

  $dbVar->do(qq(CREATE table tmp_pop2
                SELECT tp.name as name, tp.pop_id as pop_id,
                       p.population_id as parent_population_id
                FROM   tmp_pop tp, tmp_pop_count tpc, population p
                WHERE  p.name = 'MULTI-NATIONAL'
                AND    tpc.pop_id = tp.pop_id
                AND    tpc.count > 1));

  $dbVar->do(qq{INSERT INTO population (name, parent_population_id, pop_id,
                                       population_type)
                SELECT name, parent_population_id, pop_id, 'general'
                FROM   tmp_pop2});



  $dbVar->do("ALTER TABLE population ADD INDEX pop_id(pop_id)");
  $dbVar->do("ALTER TABLE population ADD INDEX pop_class_id(pop_class_id)");

  $dbVar->do("DROP TABLE tmp_pop_class");
  $dbVar->do("DROP TABLE tmp_pop");
  $dbVar->do("DROP TABLE tmp_pop2");
  $dbVar->do("DROP TABLE tmp_pop_count");

  return;
}



#
# loads the allele table
#
sub allele_table {
  debug("Dumping allele data");


  # load a temp table that can be used to reverse compliment alleles
  # we place subsnps in the same orientation as the refSNP
  dumpSQL(qq(SELECT a1.allele, a2.allele
             FROM Allele a1, Allele a2
             WHERE a1.rev_allele_id = a2.allele_id));

  create_and_load("tmp_rev_allele", "allele", "rev_allele");
  $dbVar->do("ALTER TABLE tmp_rev_allele ADD INDEX allele(allele)");

  # first load the allele data for alleles that we have population and
  # frequency data for

  dumpSQL(qq(SELECT afsp.subsnp_id, afsp.pop_id, a.allele_id, a.allele,
                    afsp.freq
             FROM   AlleleFreqBySsPop afsp, Allele a
             WHERE  afsp.allele_id = a.allele_id
             $LIMIT));

  debug("Loading allele frequency data");

  create_and_load("tmp_allele", "subsnp_id", "pop_id",
                  "allele_id", "allele", "freq");

  $dbVar->do("ALTER TABLE tmp_allele MODIFY subsnp_id INT");
  $dbVar->do("ALTER TABLE tmp_allele MODIFY pop_id    INT");
  $dbVar->do("ALTER TABLE tmp_allele MODIFY allele_id INT");

  $dbVar->do("ALTER TABLE tmp_allele ADD INDEX subsnp_id(subsnp_id)");
  $dbVar->do("ALTER TABLE tmp_allele ADD INDEX pop_id(pop_id)");

  debug("Creating allele table");

  $dbVar->do(qq(INSERT INTO allele (variation_id, allele,
                                    frequency, population_id)
                SELECT v.variation_id,
                       IF(v.substrand_reversed_flag, tra.rev_allele, tra.allele),
                       ta.freq, p.population_id
                FROM   tmp_allele ta, tmp_rev_allele tra, variation v, population p
                WHERE  ta.subsnp_id = v.subsnp_id
                AND    ta.allele = tra.allele
                AND    ta.pop_id    = p.pop_id));

  # load remaining allele data which we do not have frequence data for
  # this will not import alleles without frequency for a variation which already has
  # frequency

  $dbVar->do("DROP TABLE tmp_allele");

  debug("Loading other allele data");


  $dbVar->do(qq{CREATE TABLE tmp_allele
                SELECT v.variation_id as variation_id, tva.pop_id,
                    IF(v.substrand_reversed_flag, tra.rev_allele, tra.allele) as allele
                FROM   variation v, tmp_var_allele tva, tmp_rev_allele tra
                LEFT JOIN allele a ON a.variation_id = v.variation_id
                WHERE  tva.subsnp_id = v.subsnp_id
                AND    tva.allele = tra.allele
                AND    a.allele_id is NULL});

  $dbVar->do("ALTER TABLE tmp_allele ADD INDEX pop_id(pop_id)");

  $dbVar->do(qq{INSERT INTO allele (variation_id, allele,
                                    frequency, population_id)
                SELECT ta.variation_id, ta.allele, null, p.population_id
                FROM   tmp_allele ta 
                LEFT JOIN population p ON p.pop_id = ta.pop_id});

  $dbVar->do("DROP TABLE tmp_rev_allele");
  $dbVar->do("DROP TABLE tmp_var_allele");
  $dbVar->do("DROP TABLE tmp_allele");
}




#
# loads the flanking sequence table
#
sub flanking_sequence_table {
  ### TBD - need to reverse compliment flanking sequence if subsnp has
  ### reverse orientation to refsnp

  $dbVar->do(qq{CREATE TABLE tmp_seq (variation_id int,
                                      line_num int,
                                      type enum ('5','3'),
                                      line varchar(255),
                                      revcom tinyint)});

  # import both the 5prime and 3prime flanking sequence tables

  foreach my $type ('3','5') {

    debug("Dumping $type' flanking sequence");

    dumpSQL(qq{SELECT subsnp_id, line_num, line
               FROM SubSNPSeq$type
               $LIMIT});
    create_and_load("tmp_seq_$type", "subsnp_id", "line_num", "line");
    $dbVar->do("ALTER TABLE tmp_seq_$type MODIFY subsnp_id int");
    $dbVar->do("ALTER TABLE tmp_seq_$type MODIFY line_num int");

    $dbVar->do("ALTER TABLE tmp_seq_$type ADD INDEX subsnp_id(subsnp_id)");

    # merge the tables into a single tmp table
    $dbVar->do(qq{INSERT INTO tmp_seq (variation_id, line_num, type, line, revcom)
                  SELECT v.variation_id, ts.line_num, '$type', ts.line, v.substrand_reversed_flag
                  FROM   tmp_seq_$type ts, variation v
                  WHERE  v.subsnp_id = ts.subsnp_id});
  }

  $dbVar->do("ALTER TABLE tmp_seq ADD INDEX idx (variation_id, type, line_num)");

  my $sth = $dbVar->prepare(qq{SELECT ts.variation_id, ts.type, ts.line, ts.revcom
                               FROM   tmp_seq ts
                               ORDER BY ts.variation_id, ts.type, ts.line_num},
                            { mysql_use_result => 1 });

  $sth->execute();

  my ($vid, $type, $line, $revcom);

  $sth->bind_columns(\$vid, \$type, \$line, \$revcom);

  open(FH, ">$tmp_dir/flankingdump.txt");

  my $upstream = '';
  my $dnstream = '';
  my $cur_vid;

  debug("Rearranging flanking sequence data");

  # dump sequences to file that can be imported all at once
  while($sth->fetch()) {
    if(defined($cur_vid) && $cur_vid != $vid) {
      # if subsnp in reverse orientation to refsnp, reverse compliment flanking sequence
      if($revcom) {
        ($upstream, $dnstream) = ($dnstream, $upstream);
        reverse_comp(\$upstream);
        reverse_comp(\$dnstream);
      }

      $upstream = '\N' if(!$upstream); # null
      $dnstream = '\N' if(!$dnstream);
      print FH join("\t", $cur_vid, $upstream, $dnstream), "\n";
      $upstream = '';
      $dnstream = '';
    }
    $cur_vid  = $vid;

    if($type == 5) {
      $upstream .= $line;
    } else {
      $dnstream .= $line;
    }
  }
  $sth->finish();

  close FH;

  debug("Loading flanking sequence data");

  # import the generated data
  $dbVar->do(qq{LOAD DATA LOCAL INFILE '$tmp_dir/flankingdump.txt'
              INTO TABLE flanking_sequence});

  unlink(">$tmp_dir/flankingdump.txt");
  $dbVar->do("DROP TABLE tmp_seq_3");
  $dbVar->do("DROP TABLE tmp_seq_5");
  $dbVar->do("DROP TABLE tmp_seq");

  return;
}



sub variation_feature {

  ### TBD not sure if variations with map_weight > 1 or 2 should be
  ### imported. If they are then the map_weight needs to be set.

  debug("Dumping seq_region data");

  dumpSQL( qq{SELECT sr.seq_region_id, sr.name
              FROM   seq_region sr},
           $dbCore);

  debug("Loading seq_region data");
  create_and_load("tmp_seq_region", "seq_region_id", "name");

  $dbVar->do("ALTER TABLE tmp_seq_region ADD INDEX name(name)");


  debug("Dumping SNPLoc data");
  dumpSQL( qq{SELECT snp_id, CONCAT(contig_acc, '.', contig_ver),
                     asn_from, asn_to, IF(orientation, -1, 1)
              FROM   SNPContigLoc
              $LIMIT});


  debug("Loading SNPLoc data");

  create_and_load("tmp_contig_loc", "snp_id", "contig", "start", "end",
                  "strand");

  $dbVar->do("ALTER TABLE tmp_contig_loc ADD INDEX contig_idx(contig)");

  debug("Creating variation_feature data");

  $dbVar->do(qq{INSERT INTO variation_feature 
                       (variation_id, seq_region_id,
                        seq_region_start, seq_region_end, seq_region_strand,
                        variation_name)
                SELECT v.variation_id, ts.seq_region_id, tcl.start, tcl.end,
                       tcl.strand, v.name
                FROM   variation v, tmp_contig_loc tcl, tmp_seq_region ts
                WHERE  v.snp_id = tcl.snp_id
                AND    tcl.contig = ts.name});

  $dbVar->do("DROP TABLE tmp_contig_loc");
}

#
# loads variation_group and variation_group_variation tables from the
# contents of the HapSet and HapSetSnpList tables
#
sub variation_group {
  debug("Dumping HapSet data");

  dumpSQL(qq{SELECT CONCAT(handle, ':', hapset_name), 1, hapset_id
             FROM HapSet});

  $dbVar->do("ALTER TABLE variation_group add column hapset_id int");

  debug("Loading variation_group");

  load('variation_group', 'name', 'source_id', 'hapset_id');

  $dbVar->do("ALTER TABLE variation_group ADD INDEX hapset_id(hapset_id)");

  debug("Dumping HapSetSnpList data");

  dumpSQL(qq{SELECT hapset_id, subsnp_id
             FROM   HapSetSnpList});

  debug("Loading variation_group_variation");

  create_and_load('tmp_variation_group', 'hapset_id', 'subsnp_id');

  $dbVar->do("ALTER TABLE tmp_variation_group MODIFY hapset_id INT");
  $dbVar->do("ALTER TABLE tmp_variation_group MODIFY subsnp_id INT");
  $dbVar->do("ALTER TABLE tmp_variation_group ADD INDEX subsnp_id(subsnp_id)");
  $dbVar->do("ALTER TABLE tmp_variation_group ADD INDEX hapset_id(hapset_id)");

  $dbVar->do(qq{INSERT INTO variation_group_variation
                     (variation_group_id, variation_id)
                SELECT vg.variation_group_id, v.variation_id
                FROM   variation_group vg, variation v, tmp_variation_group tvg
                WHERE  tvg.hapset_id = vg.hapset_id
                AND    tvg.subsnp_id = v.subsnp_id});

  $dbVar->do("DROP TABLE tmp_variation_group");
}

#
# loads allele_group table
#
sub allele_group {
  debug("Dumping Hap data");

  dumpSQL(qq{SELECT hap_id, hapset_id, loc_hap_id
             FROM   Hap});

  $dbVar->do(qq{ALTER TABLE allele_group ADD COLUMN hap_id int});

  debug("Loading allele_group");

  create_and_load('tmp_allele_group', 'hap_id', 'hapset_id', 'name');

  $dbVar->do(qq{INSERT INTO allele_group (variation_group_id, name, source_id,
                                          hap_id)
                SELECT vg.variation_group_id, tag.name, 1, tag.hap_id
                FROM   variation_group vg, tmp_allele_group tag
                WHERE  vg.hapset_id = tag.hapset_id});

  $dbVar->do(qq{ALTER TABLE allele_group ADD INDEX hap_id(hap_id)});

  debug("Dumping HapSnpAllele data");

  # This query takes an arbitrary allele which has the same nucleotide,
  # but different population. This should probably be done in a better way.

  dumpSQL(qq{SELECT hap_id, subsnp_id, snp_allele
             FROM   HapSnpAllele});

  debug("Loading allele_group_allele");

  create_and_load('tmp_allele_group_allele','hap_id','subsnp_id','snp_allele');

  $dbVar->do("ALTER TABLE tmp_allele_group_allele MODIFY hap_id INT");
  $dbVar->do("ALTER TABLE tmp_allele_group_allele ADD INDEX hap_id(hap_id)");

  $dbVar->do("ALTER TABLE tmp_allele_group_allele MODIFY subsnp_id INT");
  $dbVar->do("ALTER TABLE tmp_allele_group_allele ADD INDEX subsnp_id(subsnp_id)");

  $dbVar->do(qq{INSERT INTO allele_group_allele (allele_group_id, variation_id, allele)
                SELECT ag.allele_group_id, v.variation_id, taga.snp_allele
                FROM   allele_group ag, tmp_allele_group_allele taga, variation v
                WHERE  ag.hap_id = taga.hap_id
                AND    v.subsnp_id = taga.subsnp_id});

  $dbVar->do("DROP TABLE tmp_allele_group");
  $dbVar->do("DROP TABLE tmp_allele_group_allele");
}



#
# loads individuals into the population table, and loads individual genotypes
# into the genotype table
#
sub individual_genotypes {
  #
  # load individuals into the population table
  #

  debug("Dumping SubmittedIndividual data");

  dumpSQL(qq{SELECT si.pop_id, si.loc_ind_id, si.submitted_ind_id, i.descrip
             FROM   SubmittedIndividual si, Individual i
             WHERE  si.ind_id = i.ind_id});

  debug("Loading individuals into population table");

  create_and_load('tmp_sub_ind', 'pop_id', 'loc_ind_id',
                  'submitted_ind_id', 'description');

  $dbVar->do("ALTER TABLE tmp_sub_ind MODIFY pop_id INT");
  $dbVar->do("ALTER TABLE tmp_sub_ind ADD INDEX pop_id(pop_id)");

  # set the parent population ids of the individuals
  $dbVar->do(qq{CREATE TABLE tmp_pop
                SELECT tsi.loc_ind_id as name, p.population_id as parent_population_id,
                       tsi.submitted_ind_id as submitted_ind_id, tsi.description
                FROM   tmp_sub_ind tsi, population p
                WHERE  tsi.pop_id = p.pop_id});


  $dbVar->do("ALTER TABLE population ADD COLUMN submitted_ind_id int");

  $dbVar->do(qq{INSERT INTO population (name, parent_population_id, submitted_ind_id,
                                        size, population_type, description)
                SELECT name, parent_population_id, submitted_ind_id, 1, 'specific',
                       description
                FROM   tmp_pop});

  $dbVar->do("ALTER TABLE population ADD INDEX submitted_ind_id(submitted_ind_id)");


  #
  # load SubInd individual genotypes into genotype table
  #
  debug("Dumping SubInd and ObsGenotype data");
  dumpSQL(qq{SELECT si.subsnp_id, si.submitted_ind_id, og.obs
             FROM   SubInd si, ObsGenotype og
             WHERE  og.gty_id = si.gty_id
             $LIMIT});

  create_and_load("tmp_gty", 'subsnp_id', 'submitted_ind_id', 'genotype');

  # split apart the genotype strings
  my $sth = $dbVar->prepare("SELECT subsnp_id, submitted_ind_id, genotype FROM tmp_gty",
                            {mysql_use_result => 1});


  $sth->execute();

  open ( FH, ">$tmp_dir/tabledump.txt" );

  my $row;
  while($row = $sth->fetchrow_arrayref()) {
    my @row = @$row;
    ($row[2], $row[3]) = split('/', $row[2]);
    @row = map {(defined($_)) ? $_ : '\N'} @row;  # convert undefined to NULL;
    print FH join("\t", @row), "\n";
  }

  $sth->finish();
  close(FH);

  $dbVar->do("DROP TABLE tmp_gty");

  debug("Loading genotype table");

  create_and_load("tmp_gty", 'subsnp_id', 'submitted_ind_id', 'allele_1', 'allele_2');

  $dbVar->do(qq{ALTER TABLE tmp_gty MODIFY subsnp_id INT});
  $dbVar->do(qq{ALTER TABLE tmp_gty MODIFY submitted_ind_id INT});
  $dbVar->do(qq{ALTER TABLE tmp_gty ADD INDEX subsnp_id(subsnp_id)});
  $dbVar->do(qq{ALTER TABLE tmp_gty ADD INDEX submitted_ind_id(submitted_ind_id)});

  $dbVar->do(qq{INSERT INTO genotype (variation_id, allele_1, allele_2, population_id)
                SELECT v.variation_id, tg.allele_1, tg.allele_2, p.population_id
                FROM   variation v, tmp_gty tg, population p
                WHERE  v.subsnp_id = tg.subsnp_id
                AND    p.submitted_ind_id = tg.submitted_ind_id});

  $dbVar->do("DROP TABLE tmp_pop");
  $dbVar->do("DROP TABLE tmp_sub_ind");
  $dbVar->do("DROP TABLE tmp_gty");

}


#
# loads population genotypes into the 
#
sub population_genotypes {
  debug("Dumping GtyFreqBySsPop and UniGty data");

  dumpSQL(qq{SELECT gtfsp.subsnp_id, gtfsp.pop_id, gtfsp.freq, a1.allele, a2.allele
             FROM   GtyFreqBySsPop gtfsp, UniGty ug, Allele a1, Allele a2
             WHERE  gtfsp.unigty_id = ug.unigty_id
             AND    ug.allele_id_1 = a1.allele_id
             AND    ug.allele_id_2 = a2.allele_id
             $LIMIT});

  debug("loading genotype data");

  create_and_load("tmp_gty", 'subsnp_id', 'pop_id', 'freq', 'allele_1', 'allele_2');

  $dbVar->do('ALTER TABLE tmp_gty ADD INDEX subsnp_id(subsnp_id)');
  $dbVar->do('ALTER TABLE tmp_gty ADD INDEX pop_id(pop_id)');

  $dbVar->do(qq{INSERT INTO genotype (variation_id, allele_1, allele_2, frequency,
                                      population_id)
                SELECT v.variation_id, tg.allele_1, tg.allele_2, tg.freq,
                       p.population_id
                FROM   variation v, tmp_gty tg, population p
                WHERE  v.subsnp_id = tg.subsnp_id
                AND    p.pop_id = tg.pop_id});

  $dbVar->do("DROP TABLE tmp_gty");
}



# cleans up some of the necessary temporary data structures after the
# import is complete
sub cleanup {
  $dbVar->do('ALTER TABLE variation  DROP COLUMN snp_id');
  $dbVar->do('ALTER TABLE variation  DROP COLUMN subsnp_id');
  $dbVar->do('ALTER TABLE population DROP COLUMN pop_class_id');
  $dbVar->do('ALTER TABLE population DROP COLUMN pop_id');
  $dbVar->do('ALTER TABLE population DROP COLUMN submitted_ind_id');
  $dbVar->do('ALTER TABLE variation_group DROP COLUMN hapset_id');
  $dbVar->do('ALTER TABLE allele_group DROP COLUMN hap_id');
  $dbVar->do('ALTER TABLE variation DROP COLUMN substrand_reversed_flag');
  $dbVar->do("DROP TABLE tmp_seq_region");
}



# successive dumping and loading of tables is typical for this process
# dump does effectively a select into outfile without server file system access
sub dumpSQL {
  my $sql = shift;
  my $db  = shift;

  $db ||= $dbSNP;

  local *FH;

  open FH, ">$tmp_dir/tabledump.txt";

  my $sth = $db->prepare( $sql, { mysql_use_result => 1 });
  $sth->execute();
  my $first;
  while ( my $aref = $sth->fetchrow_arrayref() ) {
    $first = 1;
    for my $col ( @$aref ) {
      if ( $first ) {
        $first = 0;
      } else {
        print FH "\t";
      }
      if ( defined $col ) {
        print FH $col;
      } else {
        print FH "\\N";
      }
    }
    print FH "\n";
  }

  $sth->finish();
}


# load imports a table, optionally not all columns
# if table doesnt exist, create a varchar(255) for each column
sub load {
  my $tablename = shift;
  my @colnames = @_;

  my $cols = join( ",", @colnames );

  local *FH;
  open FH, "<$tmp_dir/tabledump.txt";
  my $sql;

  if ( @colnames ) {

    $sql = qq{
              LOAD DATA LOCAL INFILE '$tmp_dir/tabledump.txt' 
              INTO TABLE $tablename( $cols )
             };
  } else {
    $sql = qq{
              LOAD DATA LOCAL INFILE '$tmp_dir/tabledump.txt' 
              INTO TABLE $tablename
             };
  }

  $dbVar->do( $sql );

  unlink( "$tmp_dir/tabledump.txt" );
}


sub create_and_load {
  my $tablename = shift;
  my @cols = @_;

  my $sql = "CREATE TABLE $tablename ( ";
  my $create_cols = join( ",\n", map { "$_ varchar(255)" } @cols );
  $sql .= $create_cols.")";
  $dbVar->do( $sql );

  load( $tablename, @cols );
}



sub debug {
  print STDERR @_, "\n";
}


#
# prints number of rows in a given table, used for debugging
#

sub count_rows {
  my $tablename = shift;

  my ($count) = $dbVar->selectall_arrayref
                    ("SELECT count(*) FROM $tablename")->[0]->[0];

  print STDERR "table $tablename has $count rows\n";
}


#
# reverse compliments nucleotide sequence
#

sub reverse_comp {
  my $seqref = shift;

  $$seqref = reverse( $$seqref );
  $$seqref =~
    tr/acgtrymkswhbvdnxACGTRYMKSWHBVDNX/tgcayrkmswdvbhnxTGCAYRKMSWDVBHNX/;

  return;
}
