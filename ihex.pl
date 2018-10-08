#############################################################################
#                                 ihex.pl                                   #
#                                                                           #
#               A terminal based hex editor written in Perl.                #
#                                                                           #
#                Usage: perl ihex.pl || perl ihex.pl $file                  #
#                                                                           #
#                          (c)  2018 Barry Pierce                           #
#                                                                           #
#                                                                           # 
#############################################################################
use strict;
use warnings;

use Fcntl 'SEEK_SET';
use Term::ReadLine;
use Scalar::Util 'looks_like_number';

my $fh;     # file handle
my $size;   # total size of the file in bytes
my $file;   # name of the file

#------------------------------- COMMANDS ---------------------------------

#   One of a multitude of ways to do a hex dump ;)
sub print_hex_dump {
    my ($offset, $buf) = @_;
    
    for (my $i = 0; $i < length $buf; $i += 16) {
        my $output = '';
        my $chk = substr $buf, $i, 16;
        my $printable = $chk;
        $chk =~ s/(.)/sprintf "%02x ", ord $1/seg;
        
        if (length $chk > 24) {
            $chk = sprintf "%s  %s", substr($chk, 0, 24), substr($chk, 24); 
        }
        
        $output .= $chk;
        $output .= ' ' x (50 - length $chk);
        $output .= '| ';
        for my $v (unpack "C*", $printable) {
            $output .= sprintf "%c", $v > 32 && $v < 127 ? $v : ord '.';
        }
        my $fmt = $size < 0xff       ? "%02x"
                : $size < 0xffff     ? "%04x"
                : $size < 0xffffff   ? "%06x"
                : $size < 0xffffffff ? "%08x"
                :                      undef;
        
        if (!defined $fmt) {
            print "file too big to hexdump";
            return;
        }
        
        printf "$fmt %s\n", $i + $offset, $output;
    }
}

#   Open a binary file for editing
#    - closes file if currently open
#    - print error if problem opening file 
sub open_file {
    my ($file_name) = @_;
    
    if (defined $fh) {
        close_file();
    }
        
    if (!$file_name) {
        print "no file name given!\n";
        return;
    }
        
    if (!open $fh, "+<:raw:bytes", $file_name) {
        print "couldn't open $file_name $!\n";
        return;
    }
    
    $size = -s $file_name;
    $file = $file_name;
    print "$file_name is open for editing...\n";
}

#   Hex dumps $len number of bytes of the file starting at $offset. If $len is
#   omitted dumps all the bytes to the end of file.
#    - print error if problem
sub dump_hex {
    my ($offset, $len) = @_;
    
    if (!defined $len) {
        $len = $size;
    }
    
    # check $offset & $len are within bounds
    my $err = !defined $offset            ? "no offset given!"
            : !looks_like_number($offset) ? "offset must be a number!"
            : $offset < 0                 ? "offset must be positive!"
            : !looks_like_number($len)    ? "length must be a number!"
            : $len < 1                    ? "length must be greater than 1!"
            : $offset > $size             ? "offset past end of file!"
            : $len > $size - $offset      ? "length past end of file!"
            :                               undef;
        
    if ($err) {
        print "$err\n";
        return;
    }
    
    # move file handle to $offset    
    if (!seek $fh, $offset, SEEK_SET) {
        print "seek failed $!\n";
        return;
    }
    
    # read binary chunk    
    my $buf;
    if (!defined(read $fh, $buf, $len)) {
        print "couldn't read $!\n";
        return;    
    }
        
    print_hex_dump($offset, $buf);
}

#   Replaces one or more bytes starting at $offset. The replacement byte
#   values (@bytes) must be expressed as hexadecimal constants e.g something
#   like 0x0a.
#    - print error if problem
sub edit {
    my ($offset, @bytes) = @_;
    
    # check $offset is within bounds
    my $err = !defined $offset            ? "no offset given!"
            : !looks_like_number($offset) ? "offset must be a number!"
            : $offset < 0                 ? "offset must be positive!"
            : $offset > $size             ? "offset past end of file!"
            : !@bytes                     ? "no replacement byte values given!"
            :                                undef;
                
    if ($err) {
        print "$err\n";
        return;
    }
    
    # check that @bytes contains byte values encoded as hexadecimal constants
    for my $v (@bytes) {
        if ($v !~ /0x[a-f\d]{2}/i) {
            print "byte values must be hexadecimal constants!\n";
            return;
        }
    }
        
    # move file handle to $offset
    if (!seek $fh, $offset, SEEK_SET) {
        print "seek failed $!\n";
        return;
    }
    
    # convert byte values to binary blob
    my $buf = pack "C*", map { hex $_ } @bytes;
    
    # replace old values with the new ones
    if (!print $fh $buf) {
        print "couldn't write $!\n";
        return;
    }
}

#   Inspects a chunk of the file starting at $offset according to
#   the unpack template $fmt.
#    - print error if problem
sub inspect {
    my ($offset, $fmt) = @_;
    
    # check $offset is within bounds
    my $err = !defined $offset            ? "no offset given!"
            : !looks_like_number($offset) ? "offset must be a number!"
            : $offset < 0                 ? "offset must be positive!"
            : $offset > $size             ? "offset past end of file!"
            : !defined $fmt               ? "no format template given!"
            :                               undef;
                
    if ($err) {
        print "$err\n";
        return;
    }
    
    # move file handle to $offset
    if (!seek $fh, $offset, SEEK_SET) {
        print "seek failed $!\n";
        return;
    }
    
    # check template format string is valid
    my $is_ok = eval { length pack $fmt };
        
    if (!$is_ok) {
        if ($@ =~ /Invalid type ('.')/) {
            print "invalid format option $1\n";
            return;
        }
    }
    
    # read binary chunk and unpack according to the given template    
    my $buf;
    if (!defined(read $fh, $buf, length pack($fmt))) {
        print "couldn't read: $!\n";
        return;    
    }
        
    my @vals = unpack $fmt, $buf;
        
    print join(' ', unpack($fmt, $buf)), "\n";
}

#   Searches for a fixed $pattern within the file and prints the starting offset
#   of the match if it finds one. 
#    - print error if problem
sub search {
    my ($pattern) = @_;
    
    # sliding window algorithm
    my $win_size = length $pattern;

    for (my $i = 0; $i <= $size - ($win_size - 1); $i++) {
        my $buf;
        if (!seek $fh, $i, SEEK_SET) {
            print "seek failed $!\n";
            return;
        }
        if (!defined(read $fh, $buf, $win_size)) {
            print "couldn't read $!\n";
            return;    
        }
        
        if (index($buf, $pattern) != -1) {
            print "Found $pattern starting at offset: $i\n";
        }
    }
}

#   Close the file handle
sub close_file {
    if (defined $fh) {
        close $fh;
        print "closed $file\n";
        $fh = $file = $size = undef;
    }
}

#   Quits the editor
sub quit {
    close_file();
    print "goodbye for now!\n";
    exit;
}


sub help {
    print q{
                                 Commands
-----------------------------------------------------------------------------
(o)pen $file
    Opens $file for editing. Will automatically close an already open file.
      
(d)ump $offset $number_of_bytes
    Hex dumps $number_of_bytes of the file starting at $offset. If
    $number_of_bytes is omitted it will dump all the bytes to the end of the
    file.
      
(i)nspect $offset $template
    Unpacks the binary data starting at $offset using the $template string. 
    $template is a sequence of characters that gives the type and order of
    values to be inspected. See the Perl documentation for the pack/unpack
    functions for details of building templates for unpacking binary data.
    You can type (t)emplate for a list of valid and useful characters for
    building $template. Examples of using this command are:
    
    (1) i 32 n - starting at offset 32 unpack 2 bytes as as a short type in 
                 big-endian format
                 
    (2) i 16 V - starting at offset 16 unpack 4 bytes as a long type in 
                 little-endian format
    
(t)emplate
     Displays a list of valid and useful characters for building templates for
     use with the inspect command.

(e)dit $offset @replacement_bytes
    Starting at $offset replaces succesive bytes with new values. The new byte
    values (@replacement_bytes)  must be expressed as hexadecimal constants.
    For example the command: e 10 0x1f 0x1f will replace bytes 10 and 11 with
    the new values 0x1f and 0x1f respectively.
    
(s)earch "$pattern"
    Searches for $pattern in the file and prints the offset byte position of
    the match if it finds one. $pattern should be enclosed within double quotes.
    For example the command s "\x66\x6d\x74" will search thefile for the 
    pattern "\x66\x6d\x74". 
      
(q)uit
    Quits the program. Will automatically close an already open file.
    };
}


sub template {
    print q{
This is a list of the most useful characters that can be used for building
template strings for use with the inspect command. See the Perl documentation
for the pack/unpack functions for an exhaustive list of characters that can
be used. 

a   a string with arbitrary binary data, null padded

c   a signed char (8-bit)
C   an unsigned char

n   an unsigned short (16-bit) big-endian
N   an unsigned long (32-bit) big-endian

v   an unsigned short (16-bit) little-endian
V   an unsigned long (32-bit) little-endian

f   a single-precision float in native format
d   a double-precision float in native format

x   a null byte
};
}


#------------------------------- MAIN ---------------------------------------
print qq{
        ihex.pl: A terminal based hex editor written in Perl.
        
            (c) 2018 Barry Pierce => bljpierce\@gmail.com
        
 Commands: (o)pen, (d)ump, (i)nspect, (e)dit, (s)earch, (c)lose and (q)uit.
 Type (h)elp for the details.\n
};

if (defined $ARGV[0]) {
    open_file($ARGV[0]);
}

my $term = Term::ReadLine->new('ihex.pl');

# REPL
COMMAND:
while (defined($_ = $term->readline("> "))) {
    # get input from user and then split it into @tokens.
    my @tokens = split ' '; # the pattern ' ' removes leading white space
    my $cmd = shift @tokens;
    next COMMAND if !$cmd;
    
    # make sure file handle is open before we start editing
    if (grep { $_ eq $cmd } qw/inspect dump edit search i d e s/) {
        if (!defined $fh) {
            print "open a file first!\n";
            next COMMAND;
        }
    }
    
    # choose which function to call and shift @tokens to get arguments
    if ($cmd eq 'open' || $cmd eq 'o') {
        open_file(shift @tokens);
    }
    elsif ($cmd eq 'dump' || $cmd eq 'd') {
        my $offset = shift @tokens;
        my $len    = shift @tokens;
        dump_hex($offset, $len);
    }
    elsif ($cmd eq 'edit' || $cmd eq 'e') {
        my $offset = shift @tokens;
        my @bytes  = @tokens;
        edit($offset, @bytes);
    }
    elsif ($cmd eq 'inspect' || $cmd eq 'i') {
        my $offset = shift @tokens;
        my $fmt    = shift @tokens;
        inspect($offset, $fmt);
    }
    elsif ($cmd eq 'search' || $cmd eq 's') {
        my $pattern = shift @tokens;
        search(eval $pattern);
    }
    elsif ($cmd eq 'template' || $cmd eq 't') {
        template();
    }
    elsif ($cmd eq 'quit' || $cmd eq 'q') {
        quit();
    }
    elsif ($cmd eq 'help' || $cmd eq 'h') {
        help();
    }
    else {
        print "unknown command $cmd type (h)elp!\n";
    }
    $term->addhistory($_) if /\S/;
}