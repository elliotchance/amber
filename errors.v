module main

// Stage is the step of a command that failed. It's also the exit code, so it
// is the same for every command. Numbers are grouped: 2-9 general and the
// index, 10-19 backing up, 20-29 restoring.
enum Stage {
	success        = 0
	unknown        = 1 // a bug: every error should have a stage
	usage          = 2 // bad command, flag or argument
	index_missing  = 3 // the backup folder has no db.vsql
	index_exists   = 4 // init: the backup folder already exists
	create_index   = 5
	open_index     = 6
	read_index     = 7
	write_index    = 8
	read_source    = 10 // a file to back up couldn't be read or hashed
	compress       = 11
	write_object   = 12
	no_space       = 13 // max size reached
	missing_tool   = 14 // zip or unzip isn't installed
	not_found      = 20 // the path isn't in the backup at that time
	target_exists  = 21
	missing_object = 22
	decompress     = 23
	checksum       = 24
	write_target   = 25
}

struct StageError {
	Error
	stage Stage
	msg   string
}

fn (e StageError) msg() string {
	return e.msg
}

fn (e StageError) code() int {
	return int(e.stage)
}

fn stage_error(stage Stage, msg string) IError {
	return StageError{
		stage: stage
		msg:   msg
	}
}

// at gives err the stage it failed at. An error that already has a stage keeps
// it, because the innermost stage is the most specific.
fn at(stage Stage, err IError) IError {
	if err is StageError {
		return err
	}
	return stage_error(stage, err.msg())
}

// exit_code is the exit code for err.
fn exit_code(err IError) int {
	if err is StageError {
		return err.code()
	}
	return int(Stage.unknown)
}
