#!/usr/bin/env bats
load $BATS_TEST_DIRNAME/helper/common.bash
load $BATS_TEST_DIRNAME/helper/query-server-common.bash

setup() {
    setup_common
}

teardown() {
    assert_feature_version
    stop_sql_server
    teardown_common
}

setup_test_user() {
    dolt sql -q "create user test"
    dolt sql -q "grant all on *.* to test"
    dolt sql -q "delete from dolt_branch_control where user='%'"
}

@test "branch-control: fresh database. branch control tables exist" {
      run dolt sql -r csv -q "select * from dolt_branch_control"
      [ $status -eq 0 ]
      [ ${lines[0]} = "database,branch,user,host,permissions" ]
      [ ${lines[1]} = "%,%,%,%,write" ]

      dolt sql -q "select * from dolt_branch_namespace_control"

      run dolt sql -q "describe dolt_branch_control"
      [ $status -eq 0 ]
      [[ $output =~ "database" ]] || false
      [[ $output =~ "branch" ]] || false
      [[ $output =~ "user" ]] || false
      [[ $output =~ "host" ]] || false
      [[ $output =~ "permissions" ]] || false

      run dolt sql -q "describe dolt_branch_namespace_control"
      [ $status -eq 0 ]
      [[ $output =~ "database" ]] || false
      [[ $output =~ "branch" ]] || false
      [[ $output =~ "user" ]] || false
      [[ $output =~ "host" ]] || false
}

@test "branch-control: fresh database. branch control tables exist through server interface" {
    start_sql_server

    run dolt sql-client -u dolt -P $PORT --use-db "dolt_repo_$$" --result-format csv -q "select * from dolt_branch_control"
    [ $status -eq 0 ]
    [ ${lines[0]} = "database,branch,user,host,permissions" ]
    [ ${lines[1]} = "%,%,%,%,write" ]

    dolt sql-client -u dolt -P $PORT --use-db "dolt_repo_$$" -q "select * from dolt_branch_namespace_control"
}

@test "branch-control: modify dolt_branch_control from dolt sql then make sure changes are reflected" {
    setup_test_user
    dolt sql -q "insert into dolt_branch_control values ('test-db','test-branch', 'test', '%', 'write')"

    run dolt sql -r csv -q "select * from dolt_branch_control"
    [ $status -eq 0 ]
    [ ${lines[0]} = "database,branch,user,host,permissions" ]
    [ ${lines[1]} = "test-db,test-branch,test,%,write" ]

    start_sql_server
    run dolt sql-client -u dolt -P $PORT --use-db "dolt_repo_$$" --result-format csv -q "select * from dolt_branch_control"
    [ $status -eq 0 ]
    [ ${lines[0]} = "database,branch,user,host,permissions" ]
    [ ${lines[1]} = "test-db,test-branch,test,%,write" ]
}

@test "branch-control: default user root works as expected" {
    # I can't figure out how to get a dolt sql-server started as root.
    # So, I'm copying the pattern from sql-privs.bats and starting it
    # manually.
    PORT=$( definePORT )
    dolt sql-server --host 0.0.0.0 --port=$PORT &
    SERVER_PID=$! # will get killed by teardown_common
    sleep 5 # not using python wait so this works on windows

    run dolt sql-client --use-db "dolt_repo_$$" -u root -P $PORT --result-format csv -q "select * from dolt_branch_control"
    [ ${lines[0]} = "database,branch,user,host,permissions" ]
    [ ${lines[1]} = "%,%,%,%,write" ]

    dolt sql-client --use-db "dolt_repo_$$" -u root -P $PORT -q "delete from dolt_branch_control where user='%'"
     
    run dolt sql-client --use-db "dolt_repo_$$" -u root -P $PORT -q "select * from dolt_branch_control"
    [ $status -eq 0 ]
    [ "$output" == "" ] 
}

@test "branch-control: test basic branch write permissions" {
    setup_test_user

    dolt sql -q "insert into dolt_branch_control values ('dolt_repo_$$', 'test-branch', 'test', '%', 'write')"
    dolt branch test-branch
    
    start_sql_server

    run dolt sql-client -P $PORT --use-db "dolt_repo_$$" -u test -q "create table t (c1 int)"
    [ $status -ne 0 ]
    [[ $output =~ "does not have the correct permissions" ]] || false

    dolt sql-client -P $PORT --use-db "dolt_repo_$$" -u test -q "call dolt_checkout('test-branch'); create table t (c1 int)" 

    # I should also have branch permissions on branches I create
    dolt sql-client -P $PORT --use-db "dolt_repo_$$" -u test -q "call dolt_checkout('-b', 'test-branch-2'); create table t (c1 int)"

    # Now back to main. Still locked out.
    run dolt sql-client -P $PORT --use-db "dolt_repo_$$" -u test -q "create table t (c1 int)"
    [ $status -ne 0 ]
    [[ $output =~ "does not have the correct permissions" ]] || false
}

@test "branch-control: test admin permissions" {
    setup_test_user

    dolt sql -q "create user test2"
    dolt sql -q "grant all on *.* to test2"

    dolt sql -q "insert into dolt_branch_control values ('dolt_repo_$$', 'test-branch', 'test', '%', 'admin')"
    dolt branch test-branch

    start_sql_server
    
    # Admin has no write permission to branch not an admin on
    run dolt sql-client -P $PORT --use-db "dolt_repo_$$" -u test -q "create table t (c1 int)"
    [ $status -ne 0 ]
    [[ $output =~ "does not have the correct permissions" ]] || false
    
    # Admin can write
    dolt sql-client -P $PORT --use-db "dolt_repo_$$" -u test -q "call dolt_checkout('test-branch'); create table t (c1 int)"

    # Admin can make other users
    dolt sql-client -P $PORT --use-db "dolt_repo_$$" -u test -q "insert into dolt_branch_control values ('dolt_repo_$$', 'test-branch', 'test2', '%', 'write')"
    run dolt sql-client -P $PORT --use-db "dolt_repo_$$" -u test --result-format csv -q "select * from dolt_branch_control"
    [ $status -eq 0 ]
    [ ${lines[0]} = "database,branch,user,host,permissions" ]
    [ ${lines[1]} = "dolt_repo_$$,test-branch,test,%,admin" ]
    [ ${lines[2]} = "dolt_repo_$$,test-branch,test2,%,write" ]

    # test2 can see all branch permissions
    run dolt sql-client -P $PORT --use-db "dolt_repo_$$" -u test2 --result-format csv -q "select * from dolt_branch_control"
    [ $status -eq 0 ]
    [ ${lines[0]} = "database,branch,user,host,permissions" ]
    [ ${lines[1]} = "dolt_repo_$$,test-branch,test,%,admin" ]
    [ ${lines[2]} = "dolt_repo_$$,test-branch,test2,%,write" ]

    # test2 now has write permissions on test-branch
    dolt sql-client -P $PORT --use-db "dolt_repo_$$" -u test2 -q "call dolt_checkout('test-branch'); insert into t values(0)"

    # Remove test2 permissions
    dolt sql-client -P $PORT --use-db "dolt_repo_$$" -u test -q "delete from dolt_branch_control where user='test2'"

    run dolt sql-client -P $PORT --use-db "dolt_repo_$$" -u test --result-format csv -q "select * from dolt_branch_control"
    [ $status -eq 0 ]
    [ ${lines[0]} = "database,branch,user,host,permissions" ]
    [ ${lines[1]} = "dolt_repo_$$,test-branch,test,%,admin" ]

    # test2 cannot write to branch
    run dolt sql-client -P $PORT --use-db "dolt_repo_$$" -u test2 -q "call dolt_checkout('test-branch'); insert into t values(1)"
    [ $status -ne 0 ]
    [[ $output =~ "does not have the correct permissions" ]] || false
}

@test "branch-control: creating a branch grants admin permissions" {
    setup_test_user

    dolt sql -q "insert into dolt_branch_control values ('dolt_repo_$$', 'main', 'test', '%', 'write')"

    start_sql_server

    dolt sql-client -P $PORT --use-db "dolt_repo_$$" -u test -q "call dolt_branch('test-branch')"

    run dolt sql-client -P $PORT --use-db "dolt_repo_$$" -u test --result-format csv -q "select * from dolt_branch_control"
    [ $status -eq 0 ]
    [ ${lines[0]} = "database,branch,user,host,permissions" ]
    [ ${lines[1]} = "dolt_repo_$$,main,test,%,write" ]
    [ ${lines[2]} = "dolt_repo_$$,test-branch,test,%,admin" ]
}

@test "branch-control: test branch namespace control" {
    setup_test_user

    dolt sql -q "create user test2"
    dolt sql -q "grant all on *.* to test2"

    dolt sql -q "insert into dolt_branch_control values ('dolt_repo_$$', 'test-
branch', 'test', '%', 'admin')"
    dolt sql -q "insert into dolt_branch_namespace_control values ('dolt_repo_$$', 'test-%', 'test2', '%')"

    start_sql_server

    run dolt sql-client -u test -P $PORT --use-db "dolt_repo_$$" --result-format csv -q "select * from dolt_branch_namespace_control"
    [ $status -eq 0 ]
    [ ${lines[0]} = "database,branch,user,host" ]
    [ ${lines[1]} = "dolt_repo_$$,test-%,test2,%" ]

    # test cannot create test-branch
    run dolt sql-client -u test -P $PORT --use-db "dolt_repo_$$" -q "call dolt_branch('test-branch')"
    [ $status -ne 0 ]
    [[ $output =~ "cannot create a branch" ]] || false

    # test2 can create test-branch
    dolt sql-client -u test2 -P $PORT --use-db "dolt_repo_$$" -q "call dolt_branch('test-branch')"
}

@test "branch-control: test longest match in branch namespace control" {
    setup_test_user

    dolt sql -q "create user test2"
    dolt sql -q "grant all on *.* to test2"

    dolt sql -q "insert into dolt_branch_namespace_control values ('dolt_repo_$$', 'test/%', 'test', '%')"
    dolt sql -q "insert into dolt_branch_namespace_control values ('dolt_repo_$$', 'test2/%', 'test2', '%')"

    start_sql_server

    # test can create a branch in its namesapce but not in test2
    dolt sql-client -u test -P $PORT --use-db "dolt_repo_$$" -q "call dolt_branch('test/branch1')"
    run dolt sql-client -u test -P $PORT --use-db "dolt_repo_$$" -q "call dolt_branch('test2/branch1')"
    [ $status -ne 0 ]
    [[ $output =~ "cannot create a branch" ]] || false

    dolt sql-client -u test2 -P $PORT --use-db "dolt_repo_$$" -q "call dolt_branch('test2/branch1')"
    run dolt sql-client -u test2 -P $PORT --use-db "dolt_repo_$$" -q "call dolt_branch('test/branch1')"
    [ $status -ne 0 ]
    [[ $output =~ "cannot create a branch" ]] || false   
}
