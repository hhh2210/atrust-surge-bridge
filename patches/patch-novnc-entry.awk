{
    if ($0 == "        UI.start({ settings: { defaults: defaults,") {
        print "        if (typeof window.__atrustVncPassword === 'string') {"
        print "            mandatory['password'] = window.__atrustVncPassword;"
        print "            delete window.__atrustVncPassword;"
        print "        }"
        entry_patched++
    }

    print

    if ($0 == "<head>") {
        print "    <script>"
        print "        (() => {"
        print "            const fragment = new URLSearchParams(window.location.hash.slice(1));"
        print "            const password = fragment.get('password');"
        print "            if (password !== null) window.__atrustVncPassword = password;"
        print "            fragment.delete('password');"
        print "            const suffix = fragment.toString();"
        print "            window.history.replaceState(null, document.title,"
        print "                window.location.pathname + window.location.search +"
        print "                (suffix ? '#' + suffix : ''));"
        print "        })();"
        print "    </script>"
        head_patched++
    }
}

END {
    if (head_patched != 1 || entry_patched != 1) exit 42
}
