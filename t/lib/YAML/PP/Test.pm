package YAML::PP::Test;
use strict;
use warnings;

use File::Basename qw/ dirname basename /;
use Encode;
use Test::More;

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        stats => {},
        %args,
    }, $class;
    return $self;
}

sub get_tags {
    my ($class, %args) = @_;
    my %id_tags;
    my $dir = $args{test_suite_dir} . "/tags";

    return unless -d $dir;
    opendir my $dh, $dir or die $!;
    my @tags = grep { not m/^\./ } readdir $dh;
    for my $tag (sort @tags) {
        opendir my $dh, "$dir/$tag" or die $!;
        my @ids = grep { -l "$dir/$tag/$_" } readdir $dh;
        $id_tags{ $_ }->{ $tag } = 1 for @ids;
        closedir $dh;
    }
    closedir $dh;
    return %id_tags;
}

sub get_tests {
    my ($self) = @_;
    my $test_suite_dir = $self->{test_suite_dir};
    my $dir = $self->{dir};
    my $valid = $self->{valid};
    my $json = $self->{in_json};

    my @dirs;
    if (-d $test_suite_dir) {

        opendir my $dh, $test_suite_dir or die $!;
        my @ids = grep { m/^[A-Z0-9]{4}\z/ } readdir $dh;
        @ids = grep {
            $valid
            ? not -f "$test_suite_dir/$_/error"
            : -f "$test_suite_dir/$_/error"
        } @ids;
        if ($json) {
            @ids = grep {
                -f "$test_suite_dir/$_/in.json"
            } @ids;
        }
        push @dirs, map { "$test_suite_dir/$_" } @ids;
        closedir $dh;

    }
    else {
        Test::More::diag("\n############################");
        Test::More::diag("No yaml-test-suite directory");
        Test::More::diag("Using only local tests");
        Test::More::diag("############################");
    }

    opendir my $dh, $dir or die $!;
    push @dirs, map { "$dir/$_" } grep {
        m/^[iv][A-Z0-9]{3}\z/
        and (not $json or -f "$dir/$_/in.json")
    } readdir $dh;
    closedir $dh;

    return @dirs;
}

sub read_tests {
    my ($self, %args) = @_;
    my $test_suite_dir = $self->{test_suite_dir};
    my $dir = $self->{dir};
    my $skip = $args{skip};

    my @dirs;
    my @todo;

    if ($ENV{TEST_ALL}) {
        @todo = @$skip;
        @$skip = ();
    }

    if (my $dir = $ENV{YAML_TEST_DIR}) {
        @dirs = ($dir);
        @todo = ();
        @$skip = ();
    }
    else {
        @dirs = $self->get_tests();
    }

    my $skipped;
    @$skipped{ @$skip } = (1) x @$skip;

    my %todo;
    @todo{ @todo } = ();

    my @testcases;
    for my $dir (sort @dirs) {
        my $id = basename $dir;

        open my $fh, '<', "$dir/===" or die $!;
        chomp(my $title = <$fh>);
        close $fh;

        my @test_events;
        if ($self->{events}) {
            open my $fh, '<', "$dir/test.event" or die $!;
            chomp(@test_events = <$fh>);
            close $fh;
        }

        my $in_yaml;
        if ($self->{in_yaml}) {
            open my $fh, "<:encoding(UTF-8)", "$dir/in.yaml" or die $!;
            $in_yaml = do { local $/; <$fh> };
            close $fh;
        }

        my $linecount;
        if ($self->{linecount}) {
            $linecount = () = $in_yaml =~ m/\n/g;
        }

        my $out_yaml;
        if ($self->{out_yaml} and -f "$dir/out.yaml") {
            open my $fh, "<:encoding(UTF-8)", "$dir/out.yaml" or die $!;
            $out_yaml = do { local $/; <$fh> };
            close $fh;
        }

        my $emit_yaml;
        if ($self->{emit_yaml}) {
            my $file = "$dir/emit.yaml";
            unless (-f $file) {
                $file = "$dir/out.yaml";
            }
            unless (-f $file) {
                $file = "$dir/in.yaml";
            }
            open my $fh, "<:encoding(UTF-8)", $file or die $!;
            $emit_yaml = do { local $/; <$fh> };
            close $fh;
        }

        my $in_json;
        if ($self->{in_json}) {
            open my $fh, "<:encoding(UTF-8)", "$dir/in.json" or die $!;
            $in_json = do { local $/; <$fh> };
            close $fh;
        }

        my $todo = exists $todo{ $id };
        my $skip = delete $skipped->{ $id };
        my $test = {
            id => $id,
            dir => dirname($dir),
            title => $title,
            test_events => \@test_events,
            in_yaml => $in_yaml,
            out_yaml => $out_yaml,
            emit_yaml => $emit_yaml,
            in_json => $in_json,
            linecount => $linecount,
            todo => $todo,
            skip => $skip,
        };
        push @testcases, $test;
    }

    if (keys %$skipped) {
        # are there any leftover skips?
        warn __PACKAGE__.':'.__LINE__.$".Data::Dumper->Dump([\$skipped], ['skipped']);
    }
    $self->{testcases} = \@testcases;
    return (\@testcases);
}

sub run_testcases {
    my ($self, %args) = @_;
    my $testcases = $self->{testcases};
    my $code = $args{code};
    my $stats = $self->{stats};

    unless (@$testcases) {
        ok(1);
        return;
    }

    for my $testcase (@$testcases) {
        my $id = $testcase->{id};
        my $todo = $testcase->{todo};

    #    diag "------------------------------ $id";

        my $result;
        if ($testcase->{skip}) {
            SKIP: {
                push @{ $stats->{SKIP} }, $id;
                skip "SKIP $id", 1;
                $result = $code->($self, $testcase);
            }
        }
        elsif ($todo) {
            TODO: {
                local $TODO = $todo;
                $result = $code->($self, $testcase);
            }
        }
        else {
            $result = $code->($self, $testcase);
        }

    }

}

sub print_stats {
    my ($self, %args) = @_;
    my $count_fields = $args{count};
    my $list_fields = $args{ids};
    my $stats = $self->{stats};

    my $counts = '';
    for my $field (@$count_fields) {
        my $count = scalar @{ $stats->{ $field } || [] };
        $counts .= "$field: $count ";
    }
    $counts .= "\n";
    diag $counts;

    for my $field (@$list_fields) {
        my $ids = $stats->{ $field } || [];
        diag "$field: (@$ids)" if @$ids;
    }
}

sub parse_events {
    my ($class, $testcase) = @_;

    my @events;
    my $parser = YAML::PP::Parser->new(
        receiver => sub {
            my ($self, @args) = @_;
            push @events, YAML::PP::Parser->event_to_test_suite(\@args);
        },
    );
    eval {
        $parser->parse_string($testcase->{in_yaml});
    };
    my $err = $@;
    my $line = $parser->lexer->line;
    return {
        events => \@events,
        err => $err,
        parser => $parser,
        line => $line,
    };
}

sub compare_parse_events {
    my ($self, $testcase, $result) = @_;
    my $stats = $self->{stats};
    my $id = $testcase->{id};
    my $title = $testcase->{title};
    my $err = $result->{err};
    my $yaml = $testcase->{in_yaml};
    my $test_events = $testcase->{test_events};
    my $exp_lines = $testcase->{linecount};

    my @events = @{ $result->{events} };
    $_ = encode_utf8 $_ for @events;

    my $ok = 0;
    if ($err) {
        push @{ $stats->{ERROR} }, $id;
        ok(0, "$id - $title (ERROR)");
    }
    else {
        $ok = is_deeply(\@events, $test_events, "$id - $title");
    }
    if ($ok) {
        push @{ $stats->{OK} }, $id;
        if (defined $exp_lines) {
            my $lines = $result->{line};
            cmp_ok($lines, '==', $exp_lines, "$id - Line count $lines == $exp_lines");
        }
    }
    else {
        push @{ $stats->{DIFF} }, $id unless $err;
        if ($testcase->{todo}) {
            push @{ $stats->{TODO} }, $id;
        }
        if (not $testcase->{todo} or $ENV{YAML_PP_TRACE}) {
            diag "YAML:\n$yaml" unless $testcase->{todo};
            diag "EVENTS:\n" . join '', map { "$_\n" } @$test_events;
            diag "GOT EVENTS:\n" . join '', map { "$_\n" } @events;
        }
    }
}

sub compare_invalid_parse_events {
    my ($self, $testcase, $result) = @_;
    my $stats = $self->{stats};
    my $id = $testcase->{id};
    my $title = $testcase->{title};
    my $err = $result->{err};
    my $yaml = $testcase->{in_yaml};
    my $test_events = $testcase->{test_events};

    my $ok = 0;
    if (not $err) {
        push @{ $stats->{OK} }, $id;
        ok(0, "$id - $title - should be invalid");
    }
    else {
        push @{ $stats->{ERROR} }, $id;
        if (not $result->{events}) {
            $ok = ok(1, "$id - $title");
        }
        else {
            $ok = is_deeply($result->{events}, $test_events, "$id - $title");
        }
    }

    if ($ok) {
    }
    else {
        push @{ $stats->{DIFF} }, $id;
        if ($testcase->{todo}) {
            push @{ $stats->{TODO} }, $id;
        }
        if (not $testcase->{todo} or $ENV{YAML_PP_TRACE}) {
            diag "YAML:\n$yaml" unless $testcase->{todo};
            diag "EVENTS:\n" . join '', map { "$_\n" } @$test_events;
            diag "GOT EVENTS:\n" . join '', map { "$_\n" } @{ $result->{events} };
        }
    }
}

sub load_json {
    my ($self, $testcase) = @_;

    my $ypp = YAML::PP->new(boolean => 'JSON::PP');
    my @docs = eval { $ypp->load_string($testcase->{in_yaml}) };

    my $err = $@;
    return {
        data => \@docs,
        err => $err,
    };
}

sub compare_load_json {
    my ($self, $testcase, $result) = @_;
    my $stats = $self->{stats};
    my $id = $testcase->{id};
    my $title = $testcase->{title};
    my $err = $result->{err};
    my $yaml = $testcase->{in_yaml};
    my $exp_json = $testcase->{in_json};
    my $docs = $result->{data};

    # input can contain multiple JSON
    my @exp_json = split m/^(?=true|false|null|[0-9"\{\[])/m, $exp_json;
    $exp_json = '';
    my $coder = JSON::PP->new->ascii->pretty->allow_nonref->canonical;
    for my $exp (@exp_json) {
        my $data = $coder->decode($exp);
        $exp = $coder->encode($data);
        $exp_json .= $exp;
    }

    my $json = '';
    for my $doc (@$docs) {
        my $j = $coder->encode($doc);
        $json .= $j;
    }

    my $ok = 0;
    if ($err) {
        push @{ $stats->{ERROR} }, $id;
        ok(0, "$id - $title - ERROR");
    }
    else {
        $ok = cmp_ok($json, 'eq', $exp_json, "$id - load -> JSON equals expected JSON");
        if ($ok) {
            push @{ $stats->{OK} }, $id;
        }
        else {
            push @{ $stats->{DIFF} }, $id;
        }
    }

    unless ($ok) {
        if ($testcase->{todo}) {
            push @{ $stats->{TODO} }, $id;
        }
        if (not $testcase->{todo} or $ENV{YAML_PP_TRACE}) {
            diag "YAML:\n$yaml" unless $testcase->{todo};
            diag "JSON:\n" . $exp_json;
            diag "GOT JSON:\n" . $json;
        }
    }
}

sub dump_yaml {
    my ($self, $testcase) = @_;
    my $id = $testcase->{id};

    my $ypp = YAML::PP->new( boolean => 'JSON::PP' );
    my @docs = eval { $ypp->load_string($testcase->{in_yaml}) };
    my $err = $@;
    my $result = {};
    if ($err) {
        diag "ERROR loading $id";
        $result->{err} = $err;
        return $result;
    }

    my $out_yaml;
    eval {
        $out_yaml = $ypp->dump_string(@docs);
    };
    $err = $@;
    if ($err) {
        diag "ERROR dumping $id";
        $result->{err} = $err;
        return $result;
    }
    $result->{dump_yaml} = $out_yaml;

    my @reload = eval { $ypp->load_string($out_yaml) };
    $err = $@;
    if ($err) {
        diag "ERROR reloading $id";
        $result->{err} = $err;
        return $result;
    }
    $result->{data} = \@docs;
    $result->{data_reload} = \@reload;

    return $result;
}

sub compare_dump_yaml {
    my ($self, $testcase, $result) = @_;
    my $stats = $self->{stats};
    my $id = $testcase->{id};
    my $title = $testcase->{title};
    my $err = $result->{err};
    my $yaml = $testcase->{in_yaml};
    my $out_yaml = $testcase->{out_yaml};
    my $docs = $result->{data};
    my $reload_docs = $result->{data_reload};
    my $dump_yaml = $result->{dump_yaml};

    my $ok = 0;
    if ($err) {
        push @{ $stats->{ERROR} }, $id;
        ok(0, "$id - $title - ERROR");
    }
    else {
        $ok = is_deeply($reload_docs, $docs, "$id - $title - Reload data equals original");
        push @{ $stats->{DIFF} }, $id unless $ok;
    }

    if ($ok) {
        push @{ $stats->{OK} }, $id;
    }
    else {
        if ($testcase->{todo}) {
            push @{ $stats->{TODO} }, $id;
        }
        warn __PACKAGE__.':'.__LINE__.$".Data::Dumper->Dump([\$docs], ['docs']);
        if (not $testcase->{todo} or $ENV{YAML_PP_TRACE}) {
            diag "YAML:\n$out_yaml" unless $testcase->{todo};
            diag "OUT YAML:\n$out_yaml" unless $testcase->{todo};
            my $reload_dump = Data::Dumper->Dump([$reload_docs], ['reload_docs']);
            diag "RELOAD DATA:\n$reload_dump" unless $testcase->{todo};
        }
    }

}

sub emit_yaml {
    my ($self, $testcase) = @_;
    my $id = $testcase->{id};
    my $exp_yaml = $testcase->{emit_yaml};

    my @events;
    my $parser = YAML::PP::Parser->new(
        receiver => sub {
            my ($self, @args) = @_;
            push @events, [@args];
        },
    );
    eval {
        $parser->parse_string($testcase->{in_yaml});
    };

    my $result = {};
    my $err = $@;
    if ($err) {
        diag "ERROR parsing $id";
        $result->{err} = $err;
        return $result;
    }

    my $emit_yaml = $self->_emit_events(\@events);

    my @reparse_events;
    my @expected_reparse_events;
    my @ev;
    $parser = YAML::PP::Parser->new(
        receiver => sub {
            my ($self, @args) = @_;
            my ($type, $info) = @args;
            if ($type eq 'sequence_start_event' or $type eq 'mapping_start_event') {
                delete $info->{style};
            }
            push @ev, YAML::PP::Parser->event_to_test_suite(\@args);
        },
    );
    eval {
        $parser->parse_string($emit_yaml);
    };
    @reparse_events = @ev;
    @ev = ();
    eval {
        $parser->parse_string($exp_yaml);
    };
    @expected_reparse_events = @ev;
    $result = {
        expected_events => \@expected_reparse_events,
        reparse_events => \@reparse_events,
        emit_yaml => $emit_yaml,
    };
    return $result;
}

sub _emit_events {
    my ($testsuite, $events) = @_;
    my $writer = YAML::PP::Writer->new;
    my $emitter = YAML::PP::Emitter->new();
    $emitter->set_writer($writer);
    $emitter->init;
    for my $event (@$events) {
        my ($type, $info) = @$event;
        if ($type eq 'sequence_start_event' or $type eq 'mapping_start_event') {
            delete $info->{style};
        }
        $emitter->$type($info);
    }
    my $yaml = $emitter->writer->output;
    return $yaml;
}

sub compare_emit_yaml {
    my ($self, $testcase, $result) = @_;
    my $stats = $self->{stats};
    my $id = $testcase->{id};
    my $title = $testcase->{title};
    my $err = $result->{err};
    my $yaml = $testcase->{in_yaml};
    my $exp_emit_yaml = $testcase->{emit_yaml};
    my $emit_yaml = $result->{emit_yaml};
    my $exp_events = $result->{expected_events};
    my $reparse_events = $result->{reparse_events};

    if ($err) {
        push @{ $stats->{ERROR} }, $id;
        ok(0, "$id - $title - ERROR");
        return;
    }
    $_ = encode_utf8 $_ for (@$reparse_events, @$exp_events);
    my $same_events = is_deeply($reparse_events, $exp_events, "$id - $title - Events from re-parsing are the same");
    if ($same_events) {
        push @{ $stats->{SAME_EVENTS} }, $id;
        if (defined $emit_yaml) {
            $_ = encode_utf8 $_ for ($emit_yaml, $exp_emit_yaml);
            my $same_yaml = cmp_ok($emit_yaml, 'eq', $exp_emit_yaml, "$id - $title - Emit events");
            if ($same_yaml) {
                push @{ $stats->{SAME_YAML} }, $id;
            }
            else {
                push @{ $stats->{DIFF_YAML} }, $id;
            }
        }
    }
    else {
        push @{ $stats->{DIFF_EVENTS} }, $id;
    }
}

1;