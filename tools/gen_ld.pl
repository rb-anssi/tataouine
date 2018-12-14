#!/usr/bin/perl -l
use strict;

#---
# Usage: ./gen_ld.pl <arch> <board> <output_ld_file> <firm_nuum> <.config_file>
#---

# Add space between array element printing
$, =' ';

# Check the inputs
@ARGV == 5 or usage();

my $arch    = shift;
my $board   = shift;

my $out_ld  = shift;

# Specify firmware info: FW1, FW2, DFU1 or DFU2
my $firmnum = shift;

my $ada_pkg_name    = "applications";
my $out_header      = "kernel/generated/apps_layout.h";
my $out_header_ada  = "kernel/Ada/generated/$ada_pkg_name.ads";

open my $OUTLD, ">", "$out_ld" or die "unable to open $out_ld";
open my $OUTHDR, ">", "$out_header" or die "unable to open $out_header";
open my $OUTHDR_ADA, ">", "$out_header_ada" or die "unable to open $out_header_ada";

my %hash;
{
  local $/;
  %hash = (<> =~ /^CONFIG_APP_([^=]+)=(.*)/mg);
}

my $mode = uc($firmnum);
chop($mode);

my $numtasks = 0;
foreach my $i (grep {!/_/} sort(keys(%hash))) {
  next if (not defined($hash{"${i}_${mode}"}));
  $numtasks = $numtasks + 1;
}

my @apps = (grep {/.*_${mode}$/} (sort keys %hash));
my $appcnt = @apps;

#-----------------------------------------------------------------------------
# C header
#-----------------------------------------------------------------------------

print $OUTHDR <<EOF
#ifndef APP_LAYOUT_H_
#define APP_LAYOUT_H_

#include "autoconf.h"
#include "types.h"
#include "perm.h"
#include "soc-layout.h"

struct app {
    const char    *name;
    uint8_t        slot;
    uint8_t        domain;
    uint8_t        prio;
    physaddr_t     startisr;
    uint8_t        num_slots;
    uint16_t       stacksize;
    uint32_t       res_perm_reg; /* ressource permission register */
};

#define ID_APPMAX ID_APP$appcnt

static const struct app app_tab[] = {
EOF
;


#-----------------------------------------------------------------------------
# Ada header
#-----------------------------------------------------------------------------

print $OUTHDR_ADA "
------------------------------------------------------------------------
----      Copyright (c) 15-01-2018, ANSSI
----      All rights reserved.
----
---- This file is autogenerated by tools/gen_ld.pl
----
---- This file describes the applications layout and permissions for
---- the current build.
---- Please see the above script for details.
----
--------------------------------------------------------------------------

with interfaces;        use interfaces;
with types;             use types;
with ewok.tasks_shared; use ewok.tasks_shared;
with ewok.tasks;	use ewok.tasks;
with m4.mpu;
with soc.layout;    use soc.layout;

package $ada_pkg_name is

   type t_application is record
      name         : ewok.tasks.t_task_name;
      slot         : unsigned_8;
      domain       : unsigned_8;
      priority     : unsigned_8;
      num_slots    : unsigned_8;  -- How many slots are used
      stack_size   : unsigned_16;
      start_isr    : system_address;
      res_perm_reg : unsigned_32; -- ressources permission register
   end record;
";

  print $OUTHDR_ADA "
   -- list of activated applications
   subtype t_real_task_id is t_task_id
      range ID_APP1 .. ID_APP$appcnt;
";


my $slot = 1;

foreach my $i (grep {!/_/} sort(keys(%hash))) {
  next if (not defined($hash{"${i}_${mode}"}));
  print $OUTHDR_ADA "
   ${i}_name : t_task_name :=
      \"${i}\" \& \"" . " " x (10 - length(${i})) . "\";";
}

print $OUTHDR_ADA "
   list : constant array (t_real_task_id'range) of t_application := (";

#-----------------------------------------------------------------------------
# C & Ada body
#-----------------------------------------------------------------------------

my $appid = 1;

foreach my $i (grep {!/_/} sort(keys(%hash))) {
  next if (not defined($hash{"${i}_${mode}"}));
  my $num_slots = 1;
  my $domain    = 0;
  my $priority  = 0;
  my $stacksize = 8192;

  if ($hash{"${i}_NUMSLOTS"} != undef) {
    $num_slots = $hash{"${i}_NUMSLOTS"};
    # DFU slots are 2*smallers than FW ones. if the task exists in both
    # mode, it uses 2n slots in DFU mode for n slots in FW mode
    if ($mode eq 'DFU' and defined($hash{"${i}_FW"})) {
        $num_slots = $num_slots * 2;
    }
  }

  if ($hash{"${i}_STACKSIZE"} != undef) {
    $stacksize = $hash{"${i}_STACKSIZE"};
  }

  if ($hash{"${i}_DOMAIN"} != undef) {
    $domain = $hash{"${i}_DOMAIN"};
  }

  if ($hash{"${i}_PRIO"} != undef) {
    $priority = $hash{"${i}_PRIO"};
  }

  ## ressource permission register
  my $register = 0b00000000000000000000000000000000;

  # get back permission values
  my $perm_dev_dma = 0;
  my $perm_dev_crypto = 0;
  my $perm_dev_exti = 0;
  my $perm_dev_bus = 0;
  my $perm_dev_tim = 0;
  my $perm_tim_cycles = 0;
  my $perm_tsk_fisr = 0;
  my $perm_tsk_fipc = 0;
  my $perm_tsk_fc = 0;

  if ($hash{"${i}_PERM_DEV_DMA"} eq "y") { $perm_dev_dma = 1; }
  if ($hash{"${i}_PERM_DEV_CRYPTO"} != undef) { $perm_dev_crypto = $hash{"${i}_PERM_DEV_CRYPTO"}; }
  if ($hash{"${i}_PERM_DEV_BUSES"} eq "y") { $perm_dev_bus = 1; }
  if ($hash{"${i}_PERM_DEV_EXTI"} eq "y") { $perm_dev_exti = 1; }
  if ($hash{"${i}_PERM_DEV_TIM"} eq "y") { $perm_dev_tim = 1; }
  if ($hash{"${i}_PERM_TIM_GETCYCLES"} != undef) { $perm_tim_cycles = $hash{"${i}_PERM_TIM_GETCYCLES"}; }
  if ($hash{"${i}_PERM_TSK_FISR"} eq "y") { $perm_tsk_fisr = 1; }
  if ($hash{"${i}_PERM_TSK_FIPC"} eq "y") { $perm_tsk_fipc = 1; }
  if ($hash{"${i}_PERM_TSK_FC"} eq "y") { $perm_tsk_fc = 1; }

  # generate the register
  $register = ($perm_dev_dma << 31) | ($perm_dev_crypto << 29) | ($perm_dev_bus << 28) | ($perm_dev_exti << 27) | ($perm_dev_tim << 26) | ($perm_tim_cycles << 22) | ($perm_tsk_fisr << 15) | ($perm_tsk_fipc << 14) | ($perm_tsk_fc << 13);

  my $startisr = `$ENV{'CROSS_COMPILE'}nm -a build/$arch/$board/apps/\L$i\E/\L$i\E.${firmnum}.elf |grep "do_startisr"|awk '{ print \$1  }'`;
  chomp($startisr);

  print $OUTHDR "  { \"APPNAME\", $slot, $domain, $priority, 0x$startisr,  $num_slots, $stacksize, $register }," =~ s/APPNAME/\L$i\E/gr;

  # Trailing ',' to separate records
  if ($slot gt 1) {
    printf $OUTHDR_ADA ",\n";
  }

  # String in Ada are not unbounded. Here it is constants, so their size is fixed... abitrary to 16 chars.
  # Note: if name is greater than 16 compilation will fail

  $startisr =~ s/(\d{4})(\d{4})/$1_$2/;

  printf $OUTHDR_ADA "      ID_APP$appid => (${i}_name, $slot, $domain, $priority, $num_slots, $stacksize, 16#$startisr#, $register)";
  $appid = $appid + 1;

  my $totalslot = ${slot} + ${num_slots} - 1;
  print $OUTLD <<EOF

  .user_text :
  {
    _s_user_text = .;	            /* create a global symbol at data start */
    *startup*(.user_main) /* kernel code should start with its reset handler */
    *(.user_text*)
    *(.user_rodata)         	/* .rodata sections (constants, strings, etc.) */
    *(.user_rodata*)         	/* .rodata sections (constants, strings, etc.) */
    *(.glue_7)         	/* glue arm to thumb code */
    *(.glue_7t)        	/* glue thumb to arm code */
	*(.eh_frame)

    KEEP (*(.init))
    KEEP (*(.fini))

    . = ALIGN(4);
    _e_user_text = .;        	/* define a global symbols at end of code */
  } > FW${firmnum}_APP${slot}_APP${totalslot}

  /* used by the startup to initialize got */
  _s_user_igot = .;
  .user_got : AT ( _s_user_igot ) {
    . = ALIGN(4);
        _s_user_got = .;
        /*  *(.got.plt)
         *    We don't need plt segment
         *    since we do not need dynamic library relocation
         */
        *(.user_got)
        *(.user_got*)
    . = ALIGN(4);
    _e_user_got = .;
    ASSERT (((_e_user_got - _s_user_text) < _Max_User_Size), "Error: FW1 kernel .text size too big!");
  } > FW${firmnum}_APP${slot}_APP${totalslot}

  . = ALIGN(4);
  _s_user_idata = .;
  .user_data : AT (_s_user_idata )
  {
    . = ALIGN(4);
    _s_user_data = .;        /* create a global symbol at data start */
    *(.user_data)           /* .data sections */
    *(.user_data*)          /* .data* sections */
    _e_user_data = .;        /* define a global symbol at data end */
  } >RAM_APP${slot}_APP${totalslot}

  .user_bss :
  {
    /* This is used by the startup in order to initialize the .bss section */
    _s_user_bss = .;         /* define a global symbol at bss start */
    __user_bss_start__ = _s_user_bss;
    *.user_debug.o(.bss)
    *(.user_bss)
    *(.user_bss*)
    *(user_COMMON)

    . = ALIGN(4);
    _e_user_bss = .;         /* define a global symbol at bss end */
    __user_bss_end__ = _e_user_bss;
  } >RAM_APP${slot}_APP${totalslot}

    /* User_heap_stack section, used to check that there is enough RAM left */
  . = ALIGN(4);
  ._user_heap_stack :
  {
    . = ALIGN(4);
    PROVIDE ( end = . );
    PROVIDE ( _end = . );
    user_stack_start = .;
    . = . + _Min_User_Heap_Size;
    . = . + _Min_User_Stack_Size;
    user_stack_end = .;
    . = ALIGN(4);
  } >RAM_APP${slot}_APP${totalslot}

  /DISCARD/ :
  {
    *(*_stacking);
  }
EOF
 =~ s/user/\L$i\E/gr;
  $slot += $num_slots;

}


# closing app structure
print $OUTHDR "
};

";

print $OUTHDR_ADA "
   );

";

#-----------------------------------------------------------------------------
# C & Ada body, define current firmware user TXT & RAM region base & size
#-----------------------------------------------------------------------------
#
my $prefix="\U${firmnum}\L";

print $OUTHDR "
#define TXT_KERN_REGION_BASE ${prefix}_KERN_BASE
#define TXT_KERN_REGION_SIZE ${prefix}_KERN_REGION_SIZE
#define TXT_KERN_SIZE        ${prefix}_KERN_SIZE

#define TXT_USER_REGION_BASE ${prefix}_USER_BASE
#define TXT_USER_REGION_SIZE ${prefix}_USER_REGION_SIZE
#define TXT_USER_SIZE        ${prefix}_USER_SIZE
";

print $OUTHDR_ADA "
   txt_kern_region_base : constant unsigned_32   := soc.layout.${prefix}_KERN_BASE;
   txt_kern_region_size : constant m4.mpu.t_region_size := soc.layout.${prefix}_KERN_REGION_SIZE;
   txt_kern_size        : constant unsigned_32   := soc.layout.${prefix}_KERN_SIZE;

   txt_user_region_base : constant unsigned_32   := soc.layout.${prefix}_USER_BASE;
   txt_user_region_size : constant m4.mpu.t_region_size := soc.layout.${prefix}_USER_REGION_SIZE;
   txt_user_size        : constant unsigned_32   := soc.layout.${prefix}_USER_SIZE;
";

#-----------------------------------------------------------------------------
# C & Ada footer
#-----------------------------------------------------------------------------


print $OUTHDR "

#endif /*!APP_LAYOUT_H_*/
";

print $OUTHDR_ADA "

end $ada_pkg_name;
";

#---
# Utility functions
#---

sub usage()
{
  print STDERR "usage: $0  <arch> <board> <output_ld_file> <firm_num> <.config_file>";
  exit(1);
}


