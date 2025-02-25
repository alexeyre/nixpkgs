{ lib, stdenv, buildEnv, runCommand, fetchurl, file, texlive, writeShellScript, writeText }:

{

  tlpdbNix = runCommand "texlive-test-tlpdb-nix" {
    nixpkgsTlpdbNix = ../../tools/typesetting/tex/texlive/tlpdb.nix;
    tlpdbNix = texlive.tlpdb.nix;
  }
  ''
    mkdir -p "$out"
    diff -u "''${nixpkgsTlpdbNix}" "''${tlpdbNix}" | tee "$out/tlpdb.nix.patch"
  '';

  opentype-fonts = runCommand "texlive-test-opentype" {
    nativeBuildInputs = [
      (with texlive; combine { inherit scheme-medium libertinus-fonts; })
    ];
    input = builtins.toFile "opentype-testfile.tex" ''
      \documentclass{article}
      \usepackage{fontspec}
      \setmainfont{Libertinus Serif}
      \begin{document}
        \LaTeX{} is great
      \end{document}
    '';
  }
  ''
    export HOME="$(mktemp -d)"
    # We use the same testfile to test two completely different
    # font discovery mechanisms, both of which were once broken:
    #  - lualatex uses its own luaotfload script (#220228)
    #  - xelatex uses fontconfig (#228196)
    # both of the following two commands need to succeed.
    lualatex -halt-on-error "$input"
    xelatex -halt-on-error "$input"
    echo success > $out
  '';

  chktex = runCommand "texlive-test-chktex" {
    nativeBuildInputs = [
      (with texlive; combine { inherit scheme-infraonly chktex; })
    ];
    input = builtins.toFile "chktex-sample.tex" ''
      \documentclass{article}
      \begin{document}
        \LaTeX is great
      \end{document}
    '';
  } ''
    chktex -v -nall -w1 "$input" 2>&1 | tee "$out"
    grep "One warning printed" "$out"
  '';

  dvipng = lib.recurseIntoAttrs {
    # https://github.com/NixOS/nixpkgs/issues/75605
    basic = runCommand "texlive-test-dvipng-basic" {
      nativeBuildInputs = [ file texlive.combined.scheme-medium ];
      input = fetchurl {
        name = "test_dvipng.tex";
        url = "http://git.savannah.nongnu.org/cgit/dvipng.git/plain/test_dvipng.tex?id=b872753590a18605260078f56cbd6f28d39dc035";
        sha256 = "1pjpf1jvwj2pv5crzdgcrzvbmn7kfmgxa39pcvskl4pa0c9hl88n";
      };
    } ''
      cp "$input" ./document.tex

      latex document.tex
      dvipng -T tight -strict -picky document.dvi
      for f in document*.png; do
        file "$f" | tee output
        grep PNG output
      done

      mkdir "$out"
      mv document*.png "$out"/
    '';

    # test dvipng's limited capability to render postscript specials via GS
    ghostscript = runCommand "texlive-test-ghostscript" {
      nativeBuildInputs = [ file (with texlive; combine { inherit scheme-small dvipng; }) ];
      input = builtins.toFile "postscript-sample.tex" ''
        \documentclass{minimal}
        \begin{document}
          Ni
          \special{ps:
            newpath
            0 0 moveto
            7 7 rlineto
            0 7 moveto
            7 -7 rlineto
            stroke
            showpage
          }
        \end{document}
      '';
      gs_trap = writeShellScript "gs_trap.sh" ''
        exit 1
      '';
    } ''
      cp "$gs_trap" ./gs
      export PATH=$PWD:$PATH
      # check that the trap works
      gs && exit 1

      cp "$input" ./document.tex

      latex document.tex
      dvipng -T 1in,1in -strict -picky document.dvi
      for f in document*.png; do
        file "$f" | tee output
        grep PNG output
      done

      mkdir "$out"
      mv document*.png "$out"/
    '';
  };

  # https://github.com/NixOS/nixpkgs/issues/75070
  dvisvgm = runCommand "texlive-test-dvisvgm" {
    nativeBuildInputs = [ file texlive.combined.scheme-medium ];
    input = builtins.toFile "dvisvgm-sample.tex" ''
      \documentclass{article}
      \begin{document}
        mwe
      \end{document}
    '';
  } ''
    cp "$input" ./document.tex

    latex document.tex
    dvisvgm document.dvi -n -o document_dvi.svg
    cat document_dvi.svg
    file document_dvi.svg | grep SVG

    pdflatex document.tex
    dvisvgm -P document.pdf -n -o document_pdf.svg
    cat document_pdf.svg
    file document_pdf.svg | grep SVG

    mkdir "$out"
    mv document*.svg "$out"/
  '';

  texdoc = runCommand "texlive-test-texdoc" {
    nativeBuildInputs = [
      (with texlive; combine {
        inherit scheme-infraonly luatex texdoc;
        pkgFilter = pkg: lib.elem pkg.tlType [ "run" "bin" "doc" ];
      })
    ];
  } ''
    texdoc --version

    texdoc --debug --list texdoc | tee "$out"
    grep texdoc.pdf "$out"
  '';

  # test that language files are generated as expected
  hyphen-base = runCommand "texlive-test-hyphen-base" {
    hyphenBase = lib.head texlive.hyphen-base.pkgs;
    schemeFull = texlive.combined.scheme-full;
    schemeInfraOnly = texlive.combined.scheme-infraonly;
  } ''
    mkdir -p "$out"/{scheme-infraonly,scheme-full}

    # create language files with no hyphenation patterns
    cat "$hyphenBase"/tex/generic/config/language.us >language.dat
    cat "$hyphenBase"/tex/generic/config/language.us.def >language.def
    cat "$hyphenBase"/tex/generic/config/language.us.lua >language.dat.lua

    cat >>language.dat.lua <<EOF
    }
    EOF

    cat >>language.def <<EOF
    %%% No changes may be made beyond this point.

    \uselanguage {USenglish}             %%% This MUST be the last line of the file.
    EOF

    for fname in language.{dat,def,dat.lua} ; do
      diff --ignore-matching-lines='^\(%\|--\) Generated by ' -u \
        {"$hyphenBase","$schemeFull"/share/texmf-var}/tex/generic/config/"$fname" \
        | tee "$out/scheme-full/$fname.patch"
      diff --ignore-matching-lines='^\(%\|--\) Generated by ' -u \
        {,"$schemeInfraOnly"/share/texmf-var/tex/generic/config/}"$fname" \
        | tee "$out/scheme-infraonly/$fname.patch"
    done
  '';

  # test that fmtutil.cnf is fully regenerated on scheme-full
  fmtutilCnf = runCommand "texlive-test-fmtutil.cnf" {
    kpathsea = lib.head texlive.kpathsea.pkgs;
    schemeFull = texlive.combined.scheme-full;
  } ''
    mkdir -p "$out"

    diff --ignore-matching-lines='^# Generated by ' -u \
      {"$kpathsea","$schemeFull"/share/texmf-var}/web2c/fmtutil.cnf \
      | tee "$out/fmtutil.cnf.patch"
  '';

  # verify that the restricted mode gets enabled when
  # needed (detected by checking if it disallows --gscmd)
  repstopdf = runCommand "texlive-test-repstopdf" {
    nativeBuildInputs = [ (texlive.combine { inherit (texlive) scheme-infraonly epstopdf; }) ];
  } ''
    ! (epstopdf --gscmd echo /dev/null 2>&1 || true) | grep forbidden >/dev/null
    (repstopdf --gscmd echo /dev/null 2>&1 || true) | grep forbidden >/dev/null
    mkdir "$out"
  '';

  # verify that the restricted mode gets enabled when
  # needed (detected by checking if it disallows --gscmd)
  rpdfcrop = runCommand "texlive-test-rpdfcrop" {
    nativeBuildInputs = [ (texlive.combine { inherit (texlive) scheme-infraonly pdfcrop; }) ];
  } ''
    ! (pdfcrop --gscmd echo $(command -v pdfcrop) 2>&1 || true) | grep 'restricted mode' >/dev/null
    (rpdfcrop --gscmd echo $(command -v pdfcrop) 2>&1 || true) | grep 'restricted mode' >/dev/null
    mkdir "$out"
  '';

  # check that all binaries run successfully, in the following sense:
  # (1) run --version, -v, --help, -h successfully; or
  # (2) run --help, -h, or no argument with error code but show help text; or
  # (3) run successfully on a test.tex or similar file
  # we ignore the binaries that cannot be tested as above, and are either
  # compiled binaries or trivial shell wrappers
  binaries = let
      # TODO known broken binaries
      broken = [
        # *.inc files in source container rather than run
        "texaccents"

        # 'Error initialising QuantumRenderer: no suitable pipeline found'
        "tlcockpit"
      ] ++ lib.optional stdenv.isDarwin "epspdftk";  # wish shebang is a script, not a binary!

      # (1) binaries requiring -v
      shortVersion = [ "devnag" "diadia" "pmxchords" "ptex2pdf" "simpdftex" "ttf2afm" ];
      # (1) binaries requiring --help or -h
      help = [ "arlatex" "bundledoc" "cachepic" "checklistings" "dvipos" "extractres" "fig4latex" "fragmaster"
        "kpsewhere" "latex-git-log" "ltxfileinfo" "mendex" "perltex" "pn2pdf" "psbook" "psnup" "psresize" "purifyeps"
        "simpdftex" "tex2xindy" "texluac" "texluajitc" "urlbst" "yplan" ];
      shortHelp = [ "adhocfilelist" "authorindex" "bbl2bib" "bibdoiadd" "bibmradd" "biburl2doi" "bibzbladd" "ctanupload"
        "disdvi" "dvibook" "dviconcat" "getmapdl" "latex2man" "listings-ext.sh" "pygmentex" ];
      # (2) binaries that return non-zero exit code even if correctly asked for help
      ignoreExitCode = [ "authorindex" "dvibook" "dviconcat" "dvipos" "extractres" "fig4latex" "fragmaster" "latex2man"
        "latex-git-log" "listings-ext.sh" "psbook" "psnup" "psresize" "purifyeps" "tex2xindy"  "texluac"
        "texluajitc" ];
      # (2) binaries that print help on no argument, returning non-zero exit code
      noArg = [ "a2ping" "bg5+latex" "bg5+pdflatex" "bg5latex" "bg5pdflatex" "cef5latex" "cef5pdflatex" "ceflatex"
        "cefpdflatex" "cefslatex" "cefspdflatex" "chkdvifont" "dvi2fax" "dvired" "dviselect" "dvitodvi" "epsffit"
        "findhyph" "gbklatex" "gbkpdflatex" "komkindex" "kpsepath" "listbib" "listings-ext" "mag" "mathspic" "mf2pt1"
        "mk4ht" "mkt1font" "mkgrkindex" "musixflx" "pdf2ps" "pdftosrc" "pdfxup" "pedigree" "pfb2pfa" "pk2bm" "prepmx"
        "ps2pk" "psselect" "pstops" "rubibtex" "rubikrotation" "sjislatex" "sjispdflatex" "srcredact" "t4ht"
        "teckit_compile" "tex4ht" "texdiff" "texdirflatten" "texplate" "tie" "ttf2kotexfont" "ttfdump" "vlna" "vpl2ovp"
        "vpl2vpl" "yplan" ];
      # (3) binaries requiring a .tex file
      contextTest = [ "htcontext" ];
      latexTest = [ "de-macro" "e2pall" "htlatex" "htxelatex" "makeindex" "pslatex" "rumakeindex" "tpic2pdftex"
        "wordcount" "xhlatex" ];
      texTest = [ "fontinst" "htmex" "httex" "httexi" "htxetex" ];
      # tricky binaries or scripts that are obviously working but are hard to test
      # (e.g. because they expect user input no matter the arguments)
      # (printafm comes from ghostscript, not texlive)
      ignored = [
        # compiled binaries
        "dt2dv" "dv2dt" "dvi2tty" "dvidvi" "dvispc" "otp2ocp" "outocp" "pmxab"

        # GUI scripts that accept no argument or crash without a graphics server; please test manualy
        "epspdftk" "texdoctk" "tlshell" "xasy"

        # requires Cinderella, not open source and not distributed via Nixpkgs
        "ketcindy"
      ];
      # binaries that need a combined scheme and cannot work standalone
      needScheme = [
        # pfarrei: require working kpse to find lua module
        "a5toa4"

        # bibexport: requires kpsewhich
        "bibexport"

        # crossrefware: require bibtexperllibs under TEXMFROOT
        "bbl2bib" "bibdoiadd" "bibmradd" "biburl2doi" "bibzbladd" "checkcites" "ltx2crossrefxml"

        # require other texlive binaries in PATH
        "allcm" "allec" "chkweb" "fontinst" "ht*" "installfont-tl" "kanji-config-updmap-sys" "kanji-config-updmap-user"
        "kpse*" "latexfileversion" "mkocp" "mkofm" "mtxrunjit" "pdftex-quiet" "pslatex" "rumakeindex" "texconfig"
        "texconfig-sys" "texexec" "texlinks" "texmfstart" "typeoutfileinfo" "wordcount" "xdvi" "xhlatex"

        # misc luatex binaries searching for luatex in PATH
        "citeproc-lua" "context" "contextjit" "ctanbib" "digestif" "epspdf" "l3build" "luafindfont" "luaotfload-tool"
        "luatools" "make4ht" "pmxchords" "tex4ebook" "texdoc" "texlogsieve" "xindex"

        # requires full TEXMFROOT (e.g. for config)
        "mktexfmt" "mktexmf" "mktexpk" "mktextfm" "psnup" "psresize" "pstops" "tlmgr" "updmap" "webquiz"

        # texlive-scripts: requires texlive.infra's TeXLive::TLUtils under TEXMFROOT
        "fmtutil" "fmtutil-sys" "fmtutil-user"

        # texlive-scripts: not used in nixpkgs, need updmap in PATH
        "updmap-sys" "updmap-user"
      ];

      # simple test files
      contextTestTex = writeText "context-test.tex" ''
        \starttext
          A simple test file.
        \stoptext
      '';
      latexTestTex = writeText "latex-test.tex" ''
        \documentclass{article}
        \begin{document}
          A simple test file.
        \end{document}
      '';
      texTestTex = writeText "tex-test.tex" ''
        Hello.
        \bye
      '';

      # link all binaries in single derivation
      allPackages = with lib; concatLists (catAttrs "pkgs" (filter isAttrs (attrValues texlive)));
      binPackages = lib.filter (p: p.tlType == "bin") allPackages;
      binaries = buildEnv { name = "texlive-binaries"; paths = binPackages; };
    in
    runCommand "texlive-test-binaries"
      {
        inherit binaries contextTestTex latexTestTex texTestTex;
        texliveScheme = texlive.combined.scheme-full;
      }
      ''
        loadables="$(command -v bash)"
        loadables="''${loadables%/bin/bash}/lib/bash"
        enable -f "$loadables/realpath" realpath
        mkdir -p "$out"
        export HOME="$(mktemp -d)"
        declare -i binCount=0 ignoredCount=0 brokenCount=0 failedCount=0
        cp "$contextTestTex" context-test.tex
        cp "$latexTestTex" latex-test.tex
        cp "$texTestTex" tex-test.tex

        testBin () {
          path="$(realpath "$bin")"
          path="''${path##*/}"
          if [[ -z "$ignoreExitCode" ]] ; then
            PATH="$path" "$bin" $args >"$out/$base.log" 2>&1
            ret=$?
            if [[ $ret == 0 ]] && grep -i 'command not found' "$out/$base.log" >/dev/null ; then
              echo "command not found when running '$base''${args:+ $args}'"
              return 1
            fi
            return $ret
          else
            PATH="$path" "$bin" $args >"$out/$base.log" 2>&1
            ret=$?
            if [[ $ret == 0 ]] && grep -i 'command not found' "$out/$base.log" >/dev/null ; then
              echo "command not found when running '$base''${args:+ $args}'"
              return 1
            fi
            if ! grep -Ei '(Example:|Options:|Syntax:|Usage:|improper command|SYNOPSIS)' "$out/$base.log" >/dev/null ; then
              echo "did not find usage info when running '$base''${args:+ $args}'"
              return $ret
            fi
          fi
        }

        for bin in "$binaries"/bin/* ; do
          base="''${bin##*/}"
          args=
          ignoreExitCode=
          binCount=$((binCount + 1))
          case "$base" in
            ${lib.concatStringsSep "|" ignored})
              ignoredCount=$((ignoredCount + 1))
              continue ;;
            ${lib.concatStringsSep "|" broken})
              brokenCount=$((brokenCount + 1))
              continue ;;
            ${lib.concatStringsSep "|" help})
              args=--help ;;
            ${lib.concatStringsSep "|" shortHelp})
              args=-h ;;
            ${lib.concatStringsSep "|" noArg})
              ;;
            ${lib.concatStringsSep "|" contextTest})
              args=context-test.tex ;;
            ${lib.concatStringsSep "|" latexTest})
              args=latex-test.tex ;;
            ${lib.concatStringsSep "|" texTest})
              args=tex-test.tex ;;
            ${lib.concatStringsSep "|" shortVersion})
              args=-v ;;
            ebong)
              touch empty
              args=empty ;;
            ht)
              args='latex latex-test.tex' ;;
            pdf2dsc)
              args='--help --help --help' ;;
            typeoutfileinfo)
              args=/dev/null ;;
            *)
              args=--version ;;
          esac

          case "$base" in
            ${lib.concatStringsSep "|" (ignoreExitCode ++ noArg)})
              ignoreExitCode=1 ;;
          esac

          case "$base" in
            ${lib.concatStringsSep "|" needScheme})
              bin="$texliveScheme/bin/$base"
              if [[ ! -f "$bin" ]] ; then
                ignoredCount=$((ignoredCount + 1))
                continue
              fi ;;
          esac

          if testBin ; then : ; else # preserve exit code
            echo "failed '$base''${args:+ $args}' (exit code: $?)"
            sed 's/^/  > /' < "$out/$base.log"
            failedCount=$((failedCount + 1))
          fi
        done

        echo "tested $binCount binaries: $ignoredCount ignored, $brokenCount broken, $failedCount failed"
        [[ $failedCount = 0 ]]
      '';

  # check that all scripts have a Nix shebang
  shebangs = let
      allPackages = with lib; concatLists (catAttrs "pkgs" (filter isAttrs (attrValues texlive)));
      binPackages = lib.filter (p: p.tlType == "bin") allPackages;
    in
    runCommand "texlive-test-shebangs" { }
      (''
        echo "checking that all texlive scripts shebangs are in '$NIX_STORE'"
        declare -i scriptCount=0 invalidCount=0
      '' +
      (lib.concatMapStrings
        (pkg: ''
          for bin in '${pkg.outPath}'/bin/* ; do
            grep -I -q . "$bin" || continue  # ignore binary files
            scriptCount=$((scriptCount + 1))
            read -r cmdline < "$bin"
            read -r interp <<< "$cmdline"
            if [[ "$interp" != "#!$NIX_STORE"/* && "$interp" != "#! $NIX_STORE"/* ]] ; then
              echo "error: non-nix shebang '$interp' in script '$bin'"
              invalidCount=$((invalidCount + 1))
            fi
          done
        '')
        binPackages)
      + ''
        echo "checked $scriptCount scripts, found $invalidCount non-nix shebangs"
        [[ $invalidCount -gt 0 ]] && exit 1
        mkdir -p "$out"
      ''
      );

  # verify that the precomputed licensing information in default.nix
  # does indeed match the metadata of the individual packages.
  #
  # This is part of the test suite (and not the normal evaluation) to save
  # time for "normal" evaluations. To be more in line with the other tests, this
  # also builds a derivation, even though it is essentially an eval-time assertion.
  licenses =
    let
        concatLicenses = builtins.foldl' (acc: el: if builtins.elem el acc then acc else acc ++ [ el ]);
        # converts a license to its attribute name in lib.licenses
        licenseToAttrName = license:
          builtins.head (builtins.attrNames
            (lib.filterAttrs (n: v: license == v) lib.licenses));
        lt = (a: b: a < b);

        savedLicenses = scheme: scheme.meta.license;
        savedLicensesAttrNames = scheme: map licenseToAttrName (savedLicenses scheme);

        correctLicenses = scheme: builtins.foldl'
                (acc: pkg: concatLicenses acc (lib.toList (pkg.meta.license or [])))
                []
                scheme.passthru.packages;
        correctLicensesAttrNames = scheme:
          lib.sort lt
            (map licenseToAttrName (correctLicenses scheme));

        hasLicenseMismatch = scheme:
          (lib.isDerivation scheme) &&
          (savedLicensesAttrNames scheme) != (correctLicensesAttrNames scheme);
        incorrectSchemes = lib.filterAttrs
          (n: hasLicenseMismatch)
          texlive.combined;
        prettyPrint = name: scheme:
          ''
            license info for ${name} is incorrect! Note that order is enforced.
            saved: [ ${lib.concatStringsSep " " (savedLicensesAttrNames scheme)} ]
            correct: [ ${lib.concatStringsSep " " (correctLicensesAttrNames scheme)} ]
          '';
        errorText = lib.concatStringsSep "\n\n" (lib.mapAttrsToList prettyPrint incorrectSchemes);
      in
        runCommand "texlive-test-license" {
          inherit errorText;
        }
        (if (incorrectSchemes == {})
        then "echo everything is fine! > $out"
        else ''
          echo "$errorText"
          false
        '');
}
