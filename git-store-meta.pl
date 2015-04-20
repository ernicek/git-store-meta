#!/usr/bin/perl -w
#
# =============================================================================
# Usage: git-store-meta.pl ACTION [OPTION...]
# Store, update, or apply metadata for files revisioned by git. Switch CWD to
# the top level of a git working tree before running this script.
#
# ACTION is one of:
#   -s, --store        store the metadata for all files
#   -u, --update       update the metadata for changed files
#   -a, --apply        apply the metadata stored in the data file to CWD
#   -h, --help         print this help and exit
#
# Available OPTIONs are:
#   -f, --field FIELDS fields to store or apply (see below). Default is to pick
#                      all fields in the current store file.
#   -d, --directory    also store, update, or apply for directories
#   -n, --noexec       run a test and print the output, without real action
#   -v, --verbose      apply with verbose output
#   -t, --target FILE  set another data file path
#
# FIELDS is a comma separated string combined with below values:
#   mtime   last modified time
#   atime   last access time
#   mode    unix permissions
#   user    user name
#   group   group name
#   uid     user id (if user is also set, attempt to apply user first, and then
#           fallback to uid)
#   gid     group id (if group is also set, attempt to apply group first, and
#           then fallback to gid)
#
# git-store-meta 1.0.0
# Copyright (c) 2015, Danny Lin
# Released under MIT License
# Project home: http://github.com/danny0838/git-store-meta
#
# =============================================================================

use utf8;
use strict;

use Getopt::Long;
Getopt::Long::Configure qw(gnu_getopt);
use POSIX qw( strftime );
use Time::Local;

# define constants
my $GIT_STORE_META_PREFIX    = "# generated by";
my $GIT_STORE_META_APP       = "git-store-meta";
my $GIT_STORE_META_VERSION   = "1.0.0";
my $GIT_STORE_META_FILE      = ".git_store_meta";
my $GIT                      = "git";

# environment variables
my $topdir = `$GIT rev-parse --show-cdup 2>/dev/null` || undef; chomp($topdir) if defined($topdir);
my $git_store_meta_file = ($topdir || "") . $GIT_STORE_META_FILE;
my $git_store_meta_header = join("\t", $GIT_STORE_META_PREFIX, $GIT_STORE_META_APP, $GIT_STORE_META_VERSION) . "\n";
my $script = __FILE__;
my $temp_file = $git_store_meta_file . ".tmp" . time;

# parse arguments
my %argv = (
    "store"      => 0,
    "update"     => 0,
    "apply"      => 0,
    "help"       => 0,
    "field"      => "",
    "directory"  => 0,
    "noexec"     => 0,
    "verbose"    => 0,
    "target"     => "",
);
GetOptions(
    "store|s",      \$argv{'store'},
    "update|u",     \$argv{'update'},
    "apply|a",      \$argv{'apply'},
    "help|h",       \$argv{'help'},
    "field|f=s",    \$argv{'field'},
    "directory|d",  \$argv{'directory'},
    "noexec|n",     \$argv{'noexec'},
    "verbose|v",    \$argv{'verbose'},
    "target|t=s",   \$argv{'target'},
);

# -----------------------------------------------------------------------------

sub get_file_type {
    my ($file) = @_;
    if (-l $file) {
        return "l";
    }
    elsif (-f $file) {
        return "f";
    }
    elsif (-d $file) {
        return "d";
    }
    return undef;
}

sub timestamp_to_gmtime {
    my ($timestamp) = @_;
    my @t = gmtime($timestamp);
    return strftime("%Y-%m-%dT%H:%M:%SZ", @t);
}

sub gmtime_to_timestamp {
    my ($gmtime) = @_;
    $gmtime =~ m!^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$!;
    return timegm($6, $5, $4, $3, $2 - 1, $1);
}

# escape a string to be safe to use as a shell script argument
sub escapeshellarg {
    my ($str) = @_;
    $str =~ s/'/'\\''/g;
    return "'$str'";
}

# Print the initial comment block, from first to second "# ==",
# with "# " removed
sub usage {
    my $start = 0;
    open(GIT_STORE_META, "<", $script) or die;
    while (my $line = <GIT_STORE_META>) {
        if ($line =~ m!^# ={2,}!) {
            if (!$start) { $start = 1; next; }
            else { last; }
        }
        if ($start) {
            $line =~ s/^# ?//;
            print $line;
        }
    }
    close(GIT_STORE_META);
}

# return the header and fields info of a file
sub get_cache_header_info {
    my ($file) = @_;

    my $cache_file_exist = 0;
    my $cache_file_accessible = 0;
    my $cache_header_valid = 0;
    my $app = "<?app?>";
    my $version = "<?version?>";
    my @fields;
    check: {
        -f $file || last;
        $cache_file_exist = 1;
        open(GIT_STORE_META_FILE, "<", $git_store_meta_file) || last check;
        $cache_file_accessible = 1;
        # first line: retrieve the header
        my $line = <GIT_STORE_META_FILE>;
        $line || last check;
        chomp($line);
        my @parts = split("\t", $line);
        $parts[0] eq $GIT_STORE_META_PREFIX || last check;
        $app = $parts[1];
        $version = $parts[2];
        # seconds line: retrieve the fields
        $line = <GIT_STORE_META_FILE>;
        $line || last check;
        chomp($line);
        @parts = split("\t", $line);
        for (my $i=0; $i<=$#parts; $i++) {
            $parts[$i] =~ m!^<(.*)>$! && push(@fields, $1) || last check;
        }
        (grep { $_ eq 'file' } @fields) || last check;
        (grep { $_ eq 'type' } @fields) || last check;
        close(GIT_STORE_META_FILE);
        $cache_header_valid = 1;
    };
    return ($cache_file_exist, $cache_file_accessible, $cache_header_valid, $app, $version, \@fields);
}

sub get_file_metadata {
    my ($file, $fields) = @_;
    my @fields = @{$fields};

    my @rec;
    my $type = get_file_type($file);
    return @rec if !$type;  # skip unsupported "file" types
    my ($dev, $ino, $mode, $nlink, $uid, $gid, $rdev, $size, $atime, $mtime, $ctime, $blksize, $blocks) = lstat($file);
    my ($user) = getpwuid($uid);
    my ($group) = getgrgid($gid);
    $mtime = timestamp_to_gmtime($mtime);
    $atime = timestamp_to_gmtime($atime);
    $mode = sprintf("%04o", $mode & 07777);
    my %data = (
        "file"  => $file,
        "type"  => $type,
        "mtime" => $mtime,
        "atime" => $atime,
        "mode"  => $mode,
        "uid"   => $uid,
        "gid"   => $gid,
        "user"  => $user,
        "group" => $group,
    );
    # output formatted data
    for (my $i=0; $i<=$#fields; $i++) {
        push(@rec, $data{$fields[$i]});
    }
    return @rec;
}

sub store {
    my ($fields) = @_;
    my @fields = @{$fields};

    # read the file list and write retrieved metadata to a temp file
    open(TEMP_FILE, ">", $temp_file) or die;
    open(CMD, "$GIT ls-files |") or die;
    while(<CMD>) { chomp; my $s = join("\t", get_file_metadata($_, \@fields)); print TEMP_FILE "$s\n" if $s; }
    close(CMD);
    if ($argv{'directory'}) {
        open(CMD, "$GIT ls-tree -rd --name-only \$($GIT write-tree) |") or die;
        while(<CMD>) { chomp; my $s = join("\t", get_file_metadata($_, \@fields)); print TEMP_FILE "$s\n" if $s; }
        close(CMD);
    }
    close(TEMP_FILE);

    # output sorted entries
    print $git_store_meta_header;
    print join("\t", map {"<" . $_ . ">"} @fields) . "\n";
    open(CMD, "LC_COLLATE=C sort <'$temp_file' |") or die;
    while (<CMD>) { print; }
    close(CMD);

    # clean up
    my $clear = unlink($temp_file);
}

sub update {
    my ($fields) = @_;
    my @fields = @{$fields};

    # append new entries to the temp file
    open(TEMP_FILE, ">>", $temp_file) or die;
    # go through the diff list and append entries
    open(CMD, "$GIT diff --name-status --cached |") or die;
    while(<CMD>) {
        chomp;
        my ($stat, $file) = split("\t");
        if ($stat ne "D") {
            # a modified (including added) file
            print TEMP_FILE "$file\0\2M\0\n";
            # parent directories also mark as modified
            if ($argv{'directory'}) {
                my @parts = split("/", $file);
                pop(@parts);
                while ($#parts >= 0) {
                    $file = join("/", @parts);
                    print TEMP_FILE "$file\0\2M\0\n";
                    pop(@parts);
                }
            }
        }
        else {
            # a deleted file
            print TEMP_FILE "$file\0\0D\0\n";
            # parent directories also mark as deleted (temp and could be cancelled)
            if ($argv{'directory'}) {
                my @parts = split("/", $file);
                pop(@parts);
                while ($#parts >= 0) {
                    $file = join("/", @parts);
                    print TEMP_FILE "$file\0\0D\0\n";
                    pop(@parts);
                }
            }
        }
    }
    close(CMD);
    # add all directories as a placeholder, which prevents deletion
    if ($argv{'directory'}) {
        open(CMD, "$GIT ls-tree -rd --name-only \$($GIT write-tree) |") or die;
        while(<CMD>) { chomp; print TEMP_FILE "$_\0\1H\0\n"; }
        close(CMD);
    }
    # update $git_store_meta_file if it's in the git working tree
    check_meta_file: {
        my $cmd = join(" ", ($GIT, "ls-files", "--error-unmatch", "--", escapeshellarg($git_store_meta_file), "2>&1"));
        my $file = `$cmd`;
        if ($? == 0) {
            chomp($file);
            print TEMP_FILE "$file\0\2M\0\n";
        }
    }
    close(TEMP_FILE);

    # output sorted entries
    print $git_store_meta_header;
    print join("\t", map {"<" . $_ . ">"} @fields) . "\n";
    my $cur_line = "";
    my $cur_file = "";
    my $cur_stat = "";
    my $last_file = "";
    open(CMD, "LC_COLLATE=C sort <'$temp_file' |") or die;
    # Since sorted, same paths are grouped together, with the changed entries
    # sorted prior.
    # We print the first seen entry and skip subsequent entries with a same
    # path, so that the original entry is overwritten.
    while ($cur_line = <CMD>) {
        chomp($cur_line);
        if ($cur_line =~ m!\x00[\x00-\x02]+(\w+)\x00!) {
            # has mark: a changed entry line
            $cur_stat = $1;
            $cur_line =~ s!\x00[\x00-\x02]+\w+\x00!!;
            $cur_file = $cur_line;
            if ($cur_stat eq "D") {
                # a delete => clear $cur_line so that this path is not printed
                $cur_line = "";
            }
            elsif ($cur_stat eq "H") {
                # a placeholder => recover previous "delete"
                # This is after a delete (optionally) and before a modify or
                # normal line (must). We clear $last_file so the next line will
                # see a "path change" and be printed.
                $last_file = "";
                next;
            }
        }
        else {
            # a normal line
            $cur_stat = "";
            ($cur_file) = split("\t", $cur_line);
            $cur_line .= "\n";
        }
        if ($cur_file ne $last_file) {
            if ($cur_stat eq "M") {
                # a modify => retrieve file metadata to print
                my $s = join("\t", get_file_metadata($cur_file, \@fields));
                $cur_line = $s ? "$s\n" : "";
            }
            print $cur_line;
            $last_file = $cur_file;
        }
    }
    close(CMD);
}

sub apply {
    my ($fields_used, $cache_fields, $version) = @_;
    my %fields_used = %{$fields_used};
    my @cache_fields = @{$cache_fields};

    if ($version =~ m!^1\.0\..+$!) {
        my $count = 0;
        open(GIT_STORE_META_FILE, "<", $git_store_meta_file) or die;
        while (my $line = <GIT_STORE_META_FILE>) {
            ++$count <= 2 && next;  # skip first 2 lines (header)
            $line =~ s/^\s+//; $line =~ s/\s+$//;
            next if $line eq "";

            # for each line, parse the record
            my @rec = split("\t", $line);
            my %data;
            for (my $i=0; $i<=$#cache_fields; $i++) {
                $data{$cache_fields[$i]} = $rec[$i];
            }

            # check for existence and type
            my $file = $data{'file'};
            if (! -e $file && ! -l $file) {  # -e tests symlink target instead of the symlink itself
                warn "warn: `$file' does not exist, skip applying metadata\n";
                next;
            }
            my $type = $data{'type'};
            if ($type eq "f") {
                if (! -f $file) {
                    warn "warn: `$file' is not a file, skip applying metadata\n";
                    next;
                }
            }
            elsif ($type eq "d") {
                if (! -d $file) {
                    warn "warn: `$file' is not a directory, skip applying metadata\n";
                    next;
                }
                if (!$argv{'directory'}) {
                    next;
                }
            }
            elsif ($type eq "l") {
                if (! -l $file) {
                    if (-f $file) {
                        print "`$file' is being rebuilt to a symlink.\n" if $argv{'verbose'};
                        if (!$argv{'noexec'}) {
                            my $check = 0;
                            rebuild: {
                                open(FILE, "<", $file) || last;
                                my $target = <FILE>;
                                defined($target) && $target ne "" || last;
                                chomp($target);
                                close(FILE);
                                rename($file, $temp_file) || last;
                                symlink($target, $file);
                                -l $file || last;
                                $check = 1;
                            }
                            if ($check) {
                                if (-f $temp_file) {
                                    unlink($temp_file);
                                }
                            }
                            else {
                                if (-f $temp_file) {
                                    unlink($file);
                                    rename($temp_file, $file);
                                }
                                warn "warn: `$file' cannot be rebuilt to a symlink\n";
                            }
                        }
                    }
                    else {
                        warn "warn: `$file' is not a symlink, skip applying metadata\n";
                        next;
                    }
                }
            }
            else {
                warn "warn: `$file' is recorded as an unknown type, skip applying metadata\n";
                next;
            }

            # apply metadata
            my $check = 0;
            set_user: {
                if ($fields_used{'user'} && $data{'user'} ne "") {
                    my $uid = (getpwnam($data{'user'}))[2];
                    my $gid = (lstat($file))[5];
                    print "`$file' set user to '$data{'user'}'\n" if $argv{'verbose'};
                    if ($uid) {
                        if (!$argv{'noexec'}) {
                            if (! -l $file) { $check = chown($uid, $gid, $file); }
                            else {
                                my $cmd = join(" ", ("chown", "-h", escapeshellarg($data{'user'}), escapeshellarg("./$file"), "2>&1"));
                                `$cmd`; $check = 1 if $? == 0;
                            }
                        }
                        else { $check = 1; }
                        warn "warn: `$file' cannot set user to '$data{'user'}'\n" if !$check;
                        last set_user if $check;
                    }
                    else {
                        warn "warn: $data{'user'} is not a valid user.\n";
                    }
                }
                if ($fields_used{'uid'} && $data{'uid'} ne "") {
                    my $uid = $data{'uid'};
                    my $gid = (lstat($file))[5];
                    print "`$file' set uid to '$uid'\n" if $argv{'verbose'};
                    if (!$argv{'noexec'}) {
                        if (! -l $file) { $check = chown($uid, $gid, $file); }
                        else {
                            my $cmd = join(" ", ("chown", "-h", escapeshellarg($uid), escapeshellarg("./$file"), "2>&1"));
                            `$cmd`; $check = 1 if $? == 0;
                        }
                    }
                    else { $check = 1; }
                    warn "warn: `$file' cannot set uid to '$uid'\n" if !$check;
                }
            }
            set_group: {
                if ($fields_used{'group'} && $data{'group'} ne "") {
                    my $uid = (lstat($file))[4];
                    my $gid = (getgrnam($data{'group'}))[2];
                    print "`$file' set group to '$data{'group'}'\n" if $argv{'verbose'};
                    if ($gid) {
                        if (!$argv{'noexec'}) {
                            if (! -l $file) { $check = chown($uid, $gid, $file); }
                            else {
                                my $cmd = join(" ", ("chgrp", "-h", escapeshellarg($data{'group'}), escapeshellarg("./$file"), "2>&1"));
                                `$cmd`; $check = 1 if $? == 0;
                            }
                        }
                        else { $check = 1; }
                        warn "warn: `$file' cannot set group to '$data{'group'}'\n" if !$check;
                        last set_group if $check;
                    }
                    else {
                        warn "warn: $data{'group'} is not a valid user group.\n";
                    }
                }
                if ($fields_used{'gid'} && $data{'gid'} ne "") {
                    my $uid = (lstat($file))[4];
                    my $gid = $data{'gid'};
                    print "`$file' set gid to '$gid'\n" if $argv{'verbose'};
                    if (!$argv{'noexec'}) {
                        if (! -l $file) { $check = chown($uid, $gid, $file); }
                        else {
                            my $cmd = join(" ", ("chgrp", "-h", escapeshellarg($gid), escapeshellarg("./$file"), "2>&1"));
                            `$cmd`; $check = 1 if $? == 0;
                        }
                    }
                    else { $check = 1; }
                    warn "warn: `$file' cannot set gid to '$gid'\n" if !$check;
                }
            }
            if ($fields_used{'mode'} && $data{'mode'} ne "" && ! -l $file) {
                my $mode = oct($data{'mode'}) & 07777;
                print "`$file' set mode to '$data{'mode'}'\n" if $argv{'verbose'};
                $check = !$argv{'noexec'} ? chmod($mode, $file) : 1;
                warn "warn: `$file' cannot set mode to '$data{'mode'}'\n" if !$check;
            }
            if ($fields_used{'mtime'} && $data{'mtime'} ne "") {
                my $mtime = gmtime_to_timestamp($data{'mtime'});
                my $atime = (lstat($file))[8];
                print "`$file' set mtime to '$data{'mtime'}'\n" if $argv{'verbose'};
                if (!$argv{'noexec'}) {
                    if (! -l $file) { $check = utime($atime, $mtime, $file); }
                    else {
                        my $cmd = join(" ", ("touch", "-hcmd", escapeshellarg($data{'mtime'}), escapeshellarg("./$file"), "2>&1"));
                        `$cmd`; $check = 1 if $? == 0;
                    }
                }
                else { $check = 1; }
                warn "warn: `$file' cannot set mtime to '$data{'mtime'}'\n" if !$check;
            }
            if ($fields_used{'atime'} && $data{'atime'} ne "") {
                my $mtime = (lstat($file))[9];
                my $atime = gmtime_to_timestamp($data{'atime'});
                print "`$file' set atime to '$data{'atime'}'\n" if $argv{'verbose'};
                if (!$argv{'noexec'}) {
                    if (! -l $file) { $check = utime($atime, $mtime, $file); }
                    else {
                        my $cmd = join(" ", ("touch", "-hcad", escapeshellarg($data{'atime'}), escapeshellarg("./$file"), "2>&1"));
                        `$cmd`; $check = 1 if $? == 0;
                    }
                }
                else { $check = 1; }
                warn "warn: `$file' cannot set atime to '$data{'atime'}'\n" if !$check;
            }
        }
        close(GIT_STORE_META_FILE);
    }
    else {
        die "error: current cache uses an unsupported schema of version: $version\n";
    }
}

# -----------------------------------------------------------------------------

sub main {
    # reset cache file if requested
    $git_store_meta_file = $argv{'target'} if ($argv{'target'} ne "");

    # parse header
    my ($cache_file_exist, $cache_file_accessible, $cache_header_valid, $app, $version, $cache_fields) = get_cache_header_info($git_store_meta_file);
    my @cache_fields = @{$cache_fields};

    # parse fields list
    # use $argv{'field'} if defined, or use fields in the cache file
    # special handling for --update, which must use fields in the cache file
    my %fields_used = (
        "file"  => 0,
        "type"  => 0,
        "mtime" => 0,
        "atime" => 0,
        "mode"  => 0,
        "uid"   => 0,
        "gid"   => 0,
        "user"  => 0,
        "group" => 0,
    );
    my @fields;
    my @parts;
    if (!$argv{'field'} && $cache_header_valid || $argv{'update'}) {
        @parts = @cache_fields;
    }
    else {
        push(@parts, ("file", "type"), split(/,\s*/, $argv{'field'}));
    }
    for (my $i=0; $i<=$#parts; $i++) {
        if (exists($fields_used{$parts[$i]}) && !$fields_used{$parts[$i]}) {
            $fields_used{$parts[$i]} = 1;
            push(@fields, $parts[$i]);
        }
    }
    my $field_info = "fields: " . join(", ", @fields) . "; directory: " . ($argv{'directory'} ? "yes" : "no") . "\n";

    # run action
    # priority: help > update > store > action if multiple assigned
    # update must go before store etc. since there's a special assign before
    my $action = "";
    for ('help', 'update', 'store', 'apply') { if ($argv{$_}) { $action = $_; last; } }
    if ($action eq "help") {
        usage();
    }
    elsif ($action eq "store") {
        print "storing metadata to $git_store_meta_file ...\n";
        # validate
        if (!defined($topdir) || $topdir) {
            die "error: please switch current working directory to the top level of a git working tree.\n";
        }
        # do the store
        print $field_info;
        if (!$argv{'noexec'}) {
            open(GIT_STORE_META_FILE, '>', $git_store_meta_file) or die;
            select(GIT_STORE_META_FILE);
            store(\@fields);
            close(GIT_STORE_META_FILE);
            select(STDOUT);
        }
        else {
            store(\@fields);
        }
    }
    elsif ($action eq "update") {
        print "updating metadata to $git_store_meta_file ...\n";
        # validate
        if (!defined($topdir) || $topdir) {
            die "error: please switch current working directory to the top level of a git working tree.\n";
        }
        if (!$cache_file_exist) {
            die "error: $git_store_meta_file doesn't exist.\nRun --store to create new.\n";
        }
        if (!$cache_file_accessible) {
            die "unable to access $git_store_meta_file.\n";
        }
        if ($app ne $GIT_STORE_META_APP) {
            die "error: $git_store_meta_file is using another schema: $app $version\nRun --store to create new.\n";
        }
        if ($version !~ m!^1\.0\..+$!) {
            die "error: current cache uses an unsupported schema of version: $version\n";
        }
        if (!$cache_header_valid) {
            die "$git_store_meta_file is malformatted.\nFix it or run --store to create new.\n";
        }
        # do the update
        print $field_info;
        # copy the cache file to the temp file
        # to prevent a conflict in further operation
        open(GIT_STORE_META_FILE, "<", $git_store_meta_file) or die;
        open(TEMP_FILE, ">", $temp_file) or die;
        my $count = 0;
        while (<GIT_STORE_META_FILE>) {
            if (++$count <= 2) { next; }  # discard first 2 lines
            print TEMP_FILE;
        }
        close(TEMP_FILE);
        close(GIT_STORE_META_FILE);
        # update cache
        if (!$argv{'noexec'}) {
            open(GIT_STORE_META_FILE, '>', $git_store_meta_file) or die;
            select(GIT_STORE_META_FILE);
            update(\@fields);
            close(GIT_STORE_META_FILE);
            select(STDOUT);
        }
        else {
            update(\@fields);
        }
        # clean up
        my $clear = unlink($temp_file);
    }
    elsif ($action eq "apply") {
        print "applying metadata from $git_store_meta_file ...\n";
        # validate
        if (!$cache_file_exist) {
            print "$git_store_meta_file doesn't exist, skipped.\n";
            exit;
        }
        if (!$cache_file_accessible) {
            die "unable to access $git_store_meta_file.\n";
        }
        if ($app ne $GIT_STORE_META_APP) {
            die "error: unable to apply metadata using the schema: $app $version\n";
        }
        if (!$cache_header_valid) {
            die "$git_store_meta_file is malformatted.\n";
        }
        # do the apply
        print $field_info;
        apply(\%fields_used, \@cache_fields, $version);
    }
    else {
        usage();
        exit 1;
    }
}

main();
