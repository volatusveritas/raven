function build_full()
    return(run("odin build raven -o:speed -out:build/raven_full.exe"))
end

function install_full()
    return os.rename([[build/raven_full.exe]], [[D:/Programs/raven/raven.exe]])
end

function cmd.install()
    local process = build_full()

    if not process.success then
        print("build_full failed")
        return
    end

    local move_success = install_full()

    if not move_success then
        print("Failed to move raven")
        return
    end

    print("Raven [Full] moved to install directory.")
end

function cmd.test()
    run("odin test raven -out:build/raven_test.exe")
end
