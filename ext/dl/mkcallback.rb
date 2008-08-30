$out  ||= $stdout
$dl_h = ARGV[0] || "dl.h"

# import DLSTACK_SIZE, DLSTACK_ARGS and so on
File.open($dl_h){|f|
  pre = ""
  f.each{|line|
    line.chop!
    if( line[-1] == ?\\ )
      line.chop!
      line.concat(" ")
      pre += line
      next
    end
    if( pre.size > 0 )
      line = pre + line
      pre  = ""
    end
    case line
    when /#define\s+DLSTACK_SIZE\s+\(?(\d+)\)?/
      DLSTACK_SIZE = $1.to_i
    when /#define\s+DLSTACK_ARGS\s+(.+)/
      DLSTACK_ARGS = $1.to_i
    when /#define\s+DLTYPE_([A-Z_]+)\s+\(?(\d+)\)?/
      eval("#{$1} = #{$2}")
    when /#define\s+MAX_DLTYPE\s+\(?(\d+)\)?/
      MAX_DLTYPE  = $1.to_i
    when /#define\s+MAX_CALLBACK\s+\(?(\d+)\)?/
      MAX_CALLBACK = $1.to_i
    end
  }
}

CDECL = "cdecl"
STDCALL = "stdcall"

CALLTYPES = [CDECL, STDCALL]

DLTYPE = {
  VOID => {
    :name => 'void',
    :type => 'void',
    :conv => nil,
  },
  CHAR => {
    :name => 'char',
    :type => 'char',
    :conv => 'NUM2CHR(%s)'
  },
  SHORT => {
    :name => 'short',
    :type => 'short',
    :conv => 'NUM2INT(%s)',
  },
  INT => {
    :name => 'int',
    :type => 'int',
    :conv => 'NUM2INT(%s)',
  },
  LONG  => {
    :name => 'long',
    :type => 'long',
    :conv => 'NUM2LONG(%s)',
  },
  LONG_LONG => {
    :name => 'long_long',
    :type => 'LONG_LONG',
    :conv => 'NUM2LL(%s)',
  },
  FLOAT => {
    :name => 'float',
    :type => 'float',
    :conv => 'RFLOAT_VALUE(%s)',
  },
  DOUBLE => {
    :name => 'double',
    :type => 'double',
    :conv => 'RFLOAT_VALUE(%s)',
  },
  VOIDP => {
    :name => 'ptr',
    :type => 'void *',
    :conv => 'NUM2PTR(%s)',
  },
}


def func_name(ty, argc, n, calltype)
  "rb_dl_callback_#{DLTYPE[ty][:name]}_#{argc}_#{n}_#{calltype}"
end

$out << (<<EOS)
VALUE rb_DLCdeclCallbackAddrs, rb_DLCdeclCallbackProcs;
VALUE rb_DLStdcallCallbackAddrs, rb_DLStdcallCallbackProcs;
/*static void *cdecl_callbacks[MAX_DLTYPE][MAX_CALLBACK];*/
/*static void *stdcall_callbacks[MAX_DLTYPE][MAX_CALLBACK];*/
static ID   cb_call;
EOS

def foreach_proc_entry
  for calltype in CALLTYPES
    case calltype
    when CDECL
      proc_entry = "rb_DLCdeclCallbackProcs"
    when STDCALL
      proc_entry = "rb_DLStdcallCallbackProcs"
    else
      raise "unknown calltype: #{calltype}"
    end
    yield calltype, proc_entry
  end
end

def gencallback(ty, calltype, proc_entry, argc, n)
  <<-EOS

static #{DLTYPE[ty][:type]}
FUNC_#{calltype.upcase}(#{func_name(ty,argc,n,calltype)})(#{(0...argc).collect{|i| "DLSTACK_TYPE stack" + i.to_s}.join(", ")})
{
    VALUE ret, cb#{argc > 0 ? ", args[#{argc}]" : ""};
#{
      (0...argc).collect{|i|
	"    args[%d] = LONG2NUM(stack%d);" % [i,i]
      }.join("\n")
}
    cb = rb_ary_entry(rb_ary_entry(#{proc_entry}, #{ty}), #{(n * DLSTACK_SIZE) + argc});
    ret = rb_funcall2(cb, cb_call, #{argc}, #{argc > 0 ? 'args' : 'NULL'});
    return #{DLTYPE[ty][:conv] ? DLTYPE[ty][:conv] % "ret" : ""};
}

  EOS
end

def gen_push_proc_ary(ty, aryname)
  sprintf("    rb_ary_push(#{aryname}, rb_ary_new3(%d,%s));",
          MAX_CALLBACK * DLSTACK_SIZE,
          (0...MAX_CALLBACK).collect{
            (0...DLSTACK_SIZE).collect{ "Qnil" }.join(",")
          }.join(","))
end

def gen_push_addr_ary(ty, aryname, calltype)
  sprintf("    rb_ary_push(#{aryname}, rb_ary_new3(%d,%s));",
          MAX_CALLBACK * DLSTACK_SIZE,
          (0...MAX_CALLBACK).collect{|i|
            (0...DLSTACK_SIZE).collect{|argc|
              "PTR2NUM(%s)" % func_name(ty,argc,i,calltype)
            }.join(",")
          }.join(","))
end

foreach_proc_entry do |calltype, proc_entry|
  for ty in 0..(MAX_DLTYPE-1)
    for argc in 0..(DLSTACK_SIZE-1)
      for n in 0..(MAX_CALLBACK-1)
        $out << gencallback(ty, calltype, proc_entry, argc, n)
      end
    end
  end
end

$out << (<<EOS)
static void
rb_dl_init_callbacks()
{
    VALUE tmp;
    cb_call = rb_intern("call");		       

    tmp = rb_DLCdeclCallbackProcs = rb_ary_new();
    rb_define_const(rb_mDL, "CdeclCallbackProcs", tmp);

    tmp = rb_DLCdeclCallbackAddrs = rb_ary_new();
    rb_define_const(rb_mDL, "CdeclCallbackAddrs", tmp);

    tmp = rb_DLStdcallCallbackProcs = rb_ary_new();
    rb_define_const(rb_mDL, "StdcallCallbackProcs", tmp);

    tmp = rb_DLStdcallCallbackAddrs = rb_ary_new();
    rb_define_const(rb_mDL, "StdcallCallbackAddrs", tmp);

#{
    (0...MAX_DLTYPE).collect{|ty|
      gen_push_proc_ary(ty, "rb_DLCdeclCallbackProcs")
    }.join("\n")
}
#{
    (0...MAX_DLTYPE).collect{|ty|
      gen_push_addr_ary(ty, "rb_DLCdeclCallbackAddrs", CDECL)
    }.join("\n")
}
#{
    (0...MAX_DLTYPE).collect{|ty|
      gen_push_proc_ary(ty, "rb_DLStdcallCallbackProcs")
    }.join("\n")
}
#{
    (0...MAX_DLTYPE).collect{|ty|
      gen_push_addr_ary(ty, "rb_DLStdcallCallbackAddrs", STDCALL)
    }.join("\n")
}
}
EOS
