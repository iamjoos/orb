#!/bin/bash
# orb - Oracle RMAN Backup
# Perform lvl0/lvl1/arch backup using RMAN. Tested on 11g/12c.
# ------------------------------------------------------------------------------
# Date       | Description
# ------------------------------------------------------------------------------
# 21/10/2016 | Initial version
# 08/11/2016 | Configure archivelog deletion policy if the database has standby
#            | Filter out RMAN-08120 (attempt to delete archivelog not applied to standby)
#            | Added global backup log (ORB_LOG_FILE)
# 28/11/2016 | Added "DELETE INPUT" for arch backups when rman_arch_keep_hrs=0
#            |  (see func. rman_al_delete)
#            | Added enabling of FORCE_LOGGING prior to backup
# 30/11/2016 | Renamed functions, combined parse_* and validate_* functions
#            | Improved logging
################################################################################
#-------------------------------------------------------------------------------
# CONSTANTS
#-------------------------------------------------------------------------------
PROGNAME="$(basename "$0")"
PROGDIR="$(readlink -f "$(dirname "$0")")"
CONFIG_FILE="${PROGDIR}/orb.conf"
ORB_LOG_FILE="${PROGDIR}/orb.log" # Global log file, stores info about all backups

#-------------------------------------------------------------------------------
# GLOBAL VARIABLES
#-------------------------------------------------------------------------------
gv_db_name=""               # database name
gv_backup_type=""           # backup type
gv_inst_status=""           # instance status
gv_db_role=""               # database role
gv_opt_flags=""             # additional options passed to the script
gv_log_file=""              # log file
gv_lock_file=""             # lock file
gv_rman_cmd_file=""         # RMAN command file
gv_backup_status="FAILED"   # backup status
gv_rman_format=""           # RMAN backup name format
gv_rman_tag=""              # RMAN backup tag format
gv_rman_start=""            # RMAN start time
gv_rman_end=""              # RMAN end time
gv_force_logging=""         # force logging flag

#-------------------------------------------------------------------------------
# Default configuration
#-------------------------------------------------------------------------------
# DB-specific values are set in the configuration file: ${CONFIG_FILE}
# Configuration string format: db_name.cfg.parameter=value - configuration parameters
#                              db_name.env.parameter=value - environment variables
#-------------------------------------------------------------------------------
rman_device_type="SBT_TAPE"         # RMAN device type (SBT_TAPE|DISK)
rman_env_string=""                  # RMAN environment string (mandatory for SBT_TAPE backups)
rman_backup_dest=""                 # RMAN backup destination
rman_recovery_window=7              # RMAN recovery window
rman_redundancy=""                  # RMAN redundancy
rman_channels=2                     # Number of RMAN channels
rman_compressed="no"                # Compress RMAN backups
rman_keepdays=""                    # RMAN keep until time in days
rman_tag=""                         # Custom RMAN tag
rman_arch_keep_hrs=0                # How long archivelogs should be retained after being backed up
maillist="admin@localhost"        # Comma separated list of email recipients

#-------------------------------------------------------------------------------
# Print script usage
# Globals:
#    none
# Parameters:
#    none
#-------------------------------------------------------------------------------
usage() {
    echo "Usage: ${PROGNAME} d=<db_name> t=<backup_type> [<options>]"
    echo "  db_name         - Database name defined in orb.conf"
    echo "  backup_type:"
    echo "      lvl0        - RMAN incremental level 0 backup"
    echo "      lvl1        - RMAN incremental level 1 backup"
    echo "      arch        - RMAN archivelog backup"
    echo "      archdel     - Delete archivelogs"
    echo "  options:"
    echo "      nomail      - Do not send email notifications"
    echo "      debug       - Show debug information"
    echo "      stb_only    - Perform backup only if the current database role is PHYSICAL_STANDBY"
    echo "      prm_only    - Perform backup only if the current database role is PRIMARY"
    echo "      dryrun      - Do not execute RMAN commands"

    exit 1
}

#-------------------------------------------------------------------------------
# Print a message
# Globals:
#    none
# Parameters
#    1 - message type, or message text when only one parameter passed
#    2 - message text
#-------------------------------------------------------------------------------
prn() {
    local l_msgtype
    local l_msgtext
    
    case ${#@} in
    1)
        l_msgtext="$1"
        ;;
    2)  
        l_msgtext="$2"
        l_msgtype="$1"
        ;;
    *)
        return 0
        ;;
    esac
    
    case ${l_msgtype} in
    err)
        printf "%s\n" "ERROR: ${l_msgtext}" >&2 | tee -a "${gv_log_file}"
        ;;
    inf)
        printf "%s\n" "INFO: ${l_msgtext}" | tee -a "${gv_log_file}"
        ;;
    dbg)
        check_flag debug && printf "%s\n" "DEBUG: ${l_msgtext}" | tee -a "${gv_log_file}"
        ;;
    fatal)
        printf "%s\n" "FATAL: ${l_msgtext}" >&2 | tee -a "${gv_log_file}"
        cleanup
        exit 1
        ;;
    nolog)
        printf "%s\n" "${l_msgtext}"
        ;;
    *)
        printf "%s\n" "${l_msgtext}" | tee -a ${gv_log_file}
        ;;
    esac
    
    return 0
}

#-------------------------------------------------------------------------------
# Print contents of a file
# Globals:
#    none
# Parameters:
#    1 - file name
#-------------------------------------------------------------------------------
dbgcat() {
    local l_filename="$1"
    prn "${l_filename}"
    prn "--------------------------------------------------------------------------------"
    # add "> " before each printed line
    sed 's|^|>\ |g' "${l_filename}" | tee -a "${gv_log_file}"
    prn "--------------------------------------------------------------------------------"
    return 0
}

#-------------------------------------------------------------------------------
# Check/create lock file
# Globals:
#    gv_lock_file
#    PROGDIR
# Parameters:
#    none
#-------------------------------------------------------------------------------
lockfile() {
    gv_lock_file="${PROGDIR}/${gv_db_name}.lck"
    if [[ -f "${gv_lock_file}" ]] ; then
        if kill -0 $(cat "${gv_lock_file}") 2>/dev/null ; then
            prn err "Another backup with PID=$(cat "${gv_lock_file}") is running. Exiting."
            exit 1
        else
            prn "INFO: Lock file ${gv_lock_file} exists, but no backup with PID=$(cat "${gv_lock_file}") is running. Removing lock file."
            rm "${gv_lock_file}"
        fi
    fi
    
    echo $$ > "${gv_lock_file}" 2>/dev/null || prn fatal "Unable to create lock file ${gv_lock_file}"
    return 0
}

#-------------------------------------------------------------------------------
# Read config file
# Globals:
#    gv_db_name
#    CONFIG_FILE
# Parameters:
#    none
#-------------------------------------------------------------------------------
parse_cfg() {
    local l_evar
    [[ ! -f "${CONFIG_FILE}" ]] && prn fatal "Errors encountered sourcing config file. Please make sure it exists."
    # At least one config string for gv_db_name must exist
    grep -qP "^${gv_db_name}.(env|cfg)." "${CONFIG_FILE}" || prn fatal "Unable to find database ${gv_db_name} in config file ${CONFIG_FILE}"
    # to avoid issues when the vars are exported before running the script
    unset ORACLE_HOME ORACLE_SID
    # Grep lines formatted as "db_name.(cfg|env).", remove matching pattern, and source the rest of the line
    . <(grep -oP "^${gv_db_name}.(env|cfg).\K.+" "${CONFIG_FILE}")
    # For db_name.env.xxx, export xxx
    for l_evar in $(grep -oP "^${gv_db_name}.env.\K\w+" "${CONFIG_FILE}") ; do
        export ${l_evar}
    done
    
    
    # Validations:
    case ${rman_device_type} in
    SBT_TAPE)
        [[ -z ${rman_env_string} ]] && prn fatal "Tape backups require rman_env_string to be set."
        ;;
    DISK)
        [[ -z ${rman_backup_dest} ]] && prn fatal "Backup destination (rman_backup_dest) must be set."
        mkdir -p ${rman_backup_dest} 2>/dev/null || prn fatal "Unable to create backup directory: ${rman_backup_dest}"
        ;;
    *)
        prn fatal "Unknown rman_device_type: ${rman_device_type}."
        ;;
    esac

    return 0
}

#-------------------------------------------------------------------------------
# Set env variables
# Globals:
#    ORACLE_HOME
#    ORACLE_SID
# Parameters:
#    none
#-------------------------------------------------------------------------------
setenv() {
    if [[ -z "${ORACLE_HOME}" ]] || [[ -z "${ORACLE_SID}" ]] ; then
        prn fatal "ORACLE_HOME or ORACLE_SID are not set. Please check the config file."
    elif [[ ! -d $ORACLE_HOME ]] ; then
        prn fatal "ORACLE_HOME directory ${ORACLE_HOME} doesn't exist."
    else
        export ORACLE_HOME ORACLE_SID
        export PATH=$ORACLE_HOME/bin:$PATH
        export LD_LIBRARY_PATH=$ORACLE_HOME/lib:$LD_LIBRARY_PATH
        export NLS_DATE_FORMAT="DD-MON-YYYY HH24:MI:SS"
    fi

    return 0
}

#-------------------------------------------------------------------------------
# Initialize variables
# Globals:
#    PROGDIR
#    gv_db_name
#    gv_backup_type
#    rman_device_type
#    rman_backup_dest
# Parameters:
#    none
#-------------------------------------------------------------------------------
init_log_file() {
    gv_log_file="${PROGDIR}/logs/${gv_db_name}/${gv_db_name}_${gv_backup_type}_$(date +%Y-%m-%d_%H%M%S).log"
    mkdir -p "${PROGDIR}/logs/${gv_db_name}" 2>/dev/null || prn fatal "Unable to create logs direcotry ${PROGDIR}/logs/${gv_db_name}."

    return 0
}

#-------------------------------------------------------------------------------
# Run an SQL command
# Globals:
#    ORACLE_HOME
# Parameters:
#    1 - SQL command
#-------------------------------------------------------------------------------
sql() {
    local l_cmd="${1}"

    echo "
    whenever oserror  exit 1
    whenever sqlerror exit sql.sqlcode
    set heading off echo off feedback off pagesize 0
    ${l_cmd};
    exit
    " | "${ORACLE_HOME}"/bin/sqlplus -s / as sysdba

    [[ $? != 0 ]] && prn fatal "SQL*Plus returned an error. Exiting."
    
    return 0
}

#-------------------------------------------------------------------------------
# Get instance status
# Globals:
#    gv_inst_status
# Parameters:
#    none
#-------------------------------------------------------------------------------
check_db_status() {
    gv_inst_status=$(sql "select status from v\$instance")

    case ${gv_inst_status} in
    OPEN|MOUNTED)
        ;;
    *)
        prn fatal "Instance status neither OPEN nor MOUNTED. Unable to proceed with backup."
        ;;
    esac

    return 0
}

#-------------------------------------------------------------------------------
# Get database role
# Globals:
#    gv_db_role
# Parameters:
#    none
#-------------------------------------------------------------------------------
check_db_role() {
    gv_db_role=$(sql "select database_role from v\$database")

    case ${gv_db_role} in
    PRIMARY)
        if check_flag stb_only ; then
            prn "Option stb_only specified, exiting."
            cleanup
            exit 0
        fi
        ;;
    PHYSICAL_STANDBY)
        if check_flag prm_only ; then
            prn "Option prm_only specified, exiting"
            cleanup
            exit 0
        fi
        ;;
    *)
        prn fatal "Unknown database role."
        ;;
    esac

    return 0
}

#-------------------------------------------------------------------------------
# Check if the database has a standby destination
# Globals:
#    
# Parameters:
#    none
#-------------------------------------------------------------------------------
has_standby() {
    local l_stb_num
    l_stb_num=$(sql "select count(*) from v\$archive_dest where target='STANDBY'")
    if [[ $((l_stb_num)) == 0 ]] ; then
        return 1
    else
        return 0
    fi
}

#-------------------------------------------------------------------------------
# Allocate RMAN channels
# Globals:
#    rman_channels
#    rman_device_type
#    rman_env_string
# Parameters:
#    none
#-------------------------------------------------------------------------------
rman_allocate_channels() {
    for ((i=1; i<=rman_channels; i++)) ; do
        case ${rman_device_type} in
        DISK)
            rmn "   ALLOCATE CHANNEL CH${i} DEVICE TYPE ${rman_device_type};"
            ;;
        SBT_TAPE)
            rmn "   ALLOCATE CHANNEL CH${i} DEVICE TYPE ${rman_device_type} PARMS '${rman_env_string}';"
            ;;
        esac
    done

    return 0
}

#-------------------------------------------------------------------------------
# Release RMAN channels
# Globals:
#    none
# Parameters:
#    none
#-------------------------------------------------------------------------------
rman_release_channels() {
    for ((i=1; i<=rman_channels; i++)) ; do
        rmn "   RELEASE CHANNEL CH${i};"
    done
    
    return 0
}

#-------------------------------------------------------------------------------
# Generate RMAN format string
# Globals:
#    gv_rman_format
#    rman_backup_dest
#    rman_device_type
# Parameters:
#    none
#-------------------------------------------------------------------------------
rman_format() {
    case ${rman_device_type} in
    SBT_TAPE)
        echo "${gv_rman_format}"
        ;;
    DISK)
        echo "${rman_backup_dest}/${gv_rman_format}.bkp"
        ;;
    esac

    return 0
}

#-------------------------------------------------------------------------------
# Generate RMAN tag
# Globals:
#    gv_rman_tag
#    rman_tag
#    rman_keepdays
# Parameters:
#    none
#-------------------------------------------------------------------------------
rman_tag() {
    local l_tag=""
    local l_keepuntil=""
    # if tag specified in config or cmd line, use it. Otherwise, use generic tag
    if [[ -n ${rman_tag} ]] ; then
        l_tag="${rman_tag}"
    else
        l_tag="${gv_rman_tag}"
    fi

    # add "_E{expiration_date}" to the tag if keep option specified
    if [[ -n ${rman_keepdays} ]] ; then
        l_keepuntil=$( sql "select to_char(sysdate+${rman_keepdays},'DDMMYYYY') from dual" )
        l_tag="${l_tag}_E${l_keepuntil}"
    fi

    echo ${l_tag}
    
    return 0
}

#-------------------------------------------------------------------------------
# Generate RMAN controlfile autobackup name
# Globals:
#    rman_device_type
#    rman_backup_dest
# Parameters:
#    none
#-------------------------------------------------------------------------------
rman_cf_format() {
    case ${rman_device_type} in
    SBT_TAPE)
        echo "%F"
        ;;
    DISK)
        echo "${rman_backup_dest}/%F"
        ;;
    esac

    return 0
}

#-------------------------------------------------------------------------------
# Generate RMAN retention policy
# Globals:
#    rman_redundancy
#    rman_recovery_window
# Parameters:
#    none
#-------------------------------------------------------------------------------
rman_retention() {
    # Use redundancy if it's set, otherwise use window
    if [[ -n "${rman_redundancy}" ]] ; then
        echo "REDUNDANCY ${rman_redundancy}"
    else
        echo "RECOVERY WINDOW OF ${rman_recovery_window} DAYS"
    fi

    return 0
}

#-------------------------------------------------------------------------------
# RMAN compression settings
# Globals:
#    rman_compressed
# Parameters:
#    none
#-------------------------------------------------------------------------------
rman_compress() {
    if [[ ${rman_compressed} == "yes" ]] ; then
        echo "AS COMPRESSED BACKUPSET"
    else
        echo ""
    fi

    return 0
}

#-------------------------------------------------------------------------------
# RMAN archivelogs removal
# Globals:
#    rman_arch_keep_hrs
# Parameters:
#    none
#-------------------------------------------------------------------------------
rman_al_delete() {
    if [[ ${rman_arch_keep_hrs} == 0 ]] ; then
        echo "DELETE INPUT"
    else
        echo ";"
        echo "   DELETE NOPROMPT ARCHIVELOG ALL"
        echo "       BACKED UP 1 TIMES TO DEVICE TYPE '${rman_device_type}'"
        echo "       COMPLETED BEFORE 'SYSDATE-${rman_arch_keep_hrs}/24'"
    fi
    
    return 0
}

#-------------------------------------------------------------------------------
# Generate RMAN command file
# Globals:
#    gv_db_name
#    gv_backup_type
#    gv_rman_cmd_file
#    gv_rman_format
#    gv_rman_tag
#    rman_device_type
#    rman_arch_keep_hrs
#    rman_keepdays
# Parameters:
#    none
#-------------------------------------------------------------------------------
gen_rman_cmd() {
    gv_rman_cmd_file="/tmp/${gv_db_name}_${gv_backup_type}.rman"
    cat /dev/null > ${gv_rman_cmd_file}
    
    rmn "CONNECT TARGET /;"
    rmn "CONFIGURE RETENTION POLICY TO $(rman_retention);"
    rmn "CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE ${rman_device_type} TO '$(rman_cf_format)';"
    rmn "CONFIGURE CONTROLFILE AUTOBACKUP ON;"
    has_standby && rmn "CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY;"
    rmn "RUN {"
    rman_allocate_channels

    case ${gv_backup_type} in
    archdel)
        rmn "   CROSSCHECK ARCHIVELOG ALL;"
        rmn "   DELETE NOPROMPT ARCHIVELOG ALL;"
        ;;
    arch)
        gv_rman_format="%d_al_%s_%p_%t_%T"
        gv_rman_tag="AL_$(date +%d%m%Y_%H%M)"
        
        rmn "   SQL 'ALTER SYSTEM ARCHIVE LOG CURRENT';"
        rmn "   BACKUP $(rman_compress)"
        rmn "       FORMAT '$(rman_format)'"
        rmn "       TAG '$(rman_tag)'"
        rmn "       FILESPERSET 20"
        [[ -n ${rman_keepdays} ]] && \
        rmn "       KEEP UNTIL TIME 'SYSDATE+${rman_keepdays}'"
        rmn "       ARCHIVELOG ALL NOT BACKED UP 1 TIMES"
        rmn "       $(rman_al_delete);"
        ;;
    lvl0|lvl1)
        local l_level=${gv_backup_type/lvl} # level number (0 or 1)
        
        gv_rman_format="%d_df_lvl${l_level}_%s_%p_%t_%T"
        gv_rman_tag="LVL${l_level}_$(date +%d%m%Y_%H%M)"

        rmn "   BACKUP $(rman_compress)"
        rmn "       INCREMENTAL LEVEL ${l_level}"
        rmn "       FORMAT '$(rman_format)'"
        rmn "       TAG '$(rman_tag)'"
        rmn "       FILESPERSET 1"
        [[ -n ${rman_keepdays} ]] && \
        rmn "       KEEP UNTIL TIME 'SYSDATE+${rman_keepdays}'"
        rmn "       DATABASE;"
        # archivelogs backup
        gv_rman_format="%d_al_%s_%p_%t_%T"
        gv_rman_tag="AL_$(date +%d%m%Y_%H%M)"
        # If KEEP UNTIL is NOT used, backup archivelogs
        # If KEEP UNTIL is used, RMAN will back them up automatically (11g feature)
        if [[ -z ${rman_keepdays} ]] ; then
            rmn "   SQL 'ALTER SYSTEM ARCHIVE LOG CURRENT';"
            rmn "   BACKUP $(rman_compress)"
            rmn "       FORMAT '$(rman_format)'"
            rmn "       TAG '$(rman_tag)'"
            rmn "       FILESPERSET 20"
            rmn "       ARCHIVELOG ALL NOT BACKED UP 1 TIMES"
            rmn "       $(rman_al_delete);"
        fi
        
        rmn "   DELETE NOPROMPT OBSOLETE;"
        ;;
    esac
    # CF backup
    gv_rman_format="%d_cf_%s_%p_%t_%T"
    gv_rman_tag="CF_$(date +%d%m%Y_%H%M)"
    rmn "   BACKUP $(rman_compress)"
    rmn "       FORMAT '$(rman_format)'"
    rmn "       TAG '$(rman_tag)'"
    rmn "       CURRENT CONTROLFILE;"
    rmn "   CROSSCHECK BACKUP;"
    rmn "   CROSSCHECK ARCHIVELOG ALL;"
    rman_release_channels
    rmn "}"
    
    # Post-backup reports
    rmn "LIST BACKUP SUMMARY;"
    rmn "REPORT NEED BACKUP;"
    rmn "LIST EXPIRED BACKUP;"
    rmn "LIST EXPIRED ARCHIVELOG ALL;"
    rmn "EXIT;"

    check_flag debug && dbgcat "${gv_rman_cmd_file}"
        
    return 0
}
#-------------------------------------------------------------------------------
# Execute RMAN script
# Globals:
#    gv_rman_cmd_file
#    gv_log_file
#    gv_backup_status
#    gv_rman_start
#    gv_rman_end
#    ORACLE_HOME
# Parameters:
#    none
#-------------------------------------------------------------------------------
exec_rman() {
    if check_flag dryrun ; then
        prn "dryrun option specified, skipping backup."
        gv_backup_status="SKIPPED"
        return 0
    fi

    local l_etime=$(date +%s) # uid for this backup session in the global log
    gv_rman_start=$(date +%Y-%m-%d\ %H:%M:%S)
    echo "${gv_rman_start} ${gv_db_name}:${gv_backup_type}:${l_etime}:START" >> ${ORB_LOG_FILE}
    prn "################################################################################"
    
    "${ORACLE_HOME}"/bin/rman cmdfile="${gv_rman_cmd_file}" | tee -a "${gv_log_file}"

    if [[ ${PIPESTATUS[0]} == 0 ]]; then
        gv_backup_status="SUCCESS"
        # Check RMAN log file for warnings
        # RMAN-08120 is an exception (attempt to delete archivelogs not applied to standby)
        egrep "RMAN-|ORA-" "${gv_log_file}" | egrep -v "RMAN-08120" >/dev/null 2>&1 && gv_backup_status="WARNING"
    fi

    echo ""
    prn "################################################################################"
    prn "Backup status     : ${gv_backup_status}"
    
    gv_rman_end=$(date +%Y-%m-%d\ %H:%M:%S)
    echo "${gv_rman_end} ${gv_db_name}:${gv_backup_type}:${l_etime}:${gv_backup_status}" >> ${ORB_LOG_FILE}
    
    return 0
}

#-------------------------------------------------------------------------------
# Send log file
# Globals:
#    maillist
#    gv_log_file
#    gv_backup_type
#    gv_db_name
# Parameters:
#    none
#-------------------------------------------------------------------------------
send_log() {
    local l_recipient

    check_flag nomail && return 0
    check_flag dryrun && return 0
    
    for l_recipient in ${maillist}; do
        cat "${gv_log_file}" | mailx -s "${gv_backup_status}: ${gv_backup_type} backup of ${gv_db_name}@$(hostname -s)" ${l_recipient}
    done

    prn "Email sent to: ${maillist}"
    return 0
}

#-------------------------------------------------------------------------------
# Write a command line to RMAN command file
# Globals:
#    gv_rman_cmd_file
# Parameters:
#    1 - command line
#-------------------------------------------------------------------------------
rmn() {
    echo "${1}" >> ${gv_rman_cmd_file}
    return 0
}

#-------------------------------------------------------------------------------
# Print backup header
# Globals:
#    ORACLE_SID
#    ORACLE_HOME
#    gv_backup_type
#    rman_device_type
#    rman_backup_dest
#    gv_db_role
#    gv_inst_status
#    gv_opt_flags
#    gv_log_file
#    gv_rman_start
#    gv_rman_end
# Parameters:
#    none
#-------------------------------------------------------------------------------
print_header() {
    # using 'nolog'. The header will be added to the log file with log_header()
    prn nolog "################################################################################"
    prn nolog "ORACLE_SID        : ${ORACLE_SID}"
    prn nolog "ORACLE_HOME       : ${ORACLE_HOME}"
    prn nolog "Hostname          : $(hostname)"
    prn nolog "Backup type       : ${gv_backup_type}"
    [[ ${rman_device_type} == "DISK" ]] && \
    prn nolog "Backup dest       : ${rman_backup_dest}"
    prn nolog "Database role     : ${gv_db_role}"
    prn nolog "Instance status   : ${gv_inst_status}"
    [[ -n "${gv_opt_flags}" ]] && \
    prn nolog "Additional flags  : ${gv_opt_flags}"
    prn nolog "RMAN log file     : ${gv_log_file}"
    [[ -n ${gv_rman_start} ]] && \
    prn nolog "Start time        : ${gv_rman_start}"
    [[ -n "${gv_rman_end}" ]] && \
    prn nolog "End time          : ${gv_rman_end}"
    prn nolog  "################################################################################"
}

#-------------------------------------------------------------------------------
# Enable/disable force logging
# Globals:
#    gv_force_logging
# Parameters:
#    1 - commnad (enable/disable)
#-------------------------------------------------------------------------------
force_logging() {
    check_flag dryrun && return 0
    local l_cmd="$1"
    local l_fl=""
    
    case ${l_cmd} in
    enable)
        gv_force_logging=$(sql "select force_logging from v\$database")
        if [[ ${gv_force_logging} == "NO" ]] ; then
            prn inf "Enabling FORCE_LOGGING to make sure the backup is recoverable"
            sql "alter database force logging"
            # double check force logging was enabled
            l_fl=$(sql "select force_logging from v\$database")
            [[ ${l_fl} != "YES" ]] && prn fatal "Something went wrong while enabling force logging. Exiting."
        fi
        ;;
    disable)
        # disable it only if it was enabled by the script
        if [[ ${gv_force_logging} == "NO" ]] ; then
            prn inf "Disabling FORCE_LOGGING"
            sql "alter database no force logging"
            # double check force logging was disabled
            l_fl=$(sql "select force_logging from v\$database")
            [[ ${l_fl} != "NO" ]] && prn fatal "Something went wrong while disabling force logging. Exiting."
        fi
        ;;
    *)
        prn err "Unknown command: ${l_cmd}"
        exit 1
        ;;
    esac
    
    return 0
}

#-------------------------------------------------------------------------------
# Parse command line arguments
# Globals:
#    gv_db_name
#    gv_backup_type
#    rman_keepdays
#    rman_tag
#    gv_opt_flags
# Parameters:
#    @ - all command line args
#-------------------------------------------------------------------------------
parse_args() {
    local l_arg
    for l_arg in "$@" ; do
        case ${l_arg} in
        d=*)
            gv_db_name=${l_arg/d=/}
            ;;
        t=*)
            gv_backup_type=${l_arg/t=/}
            ;;
        keep=*)
            rman_keepdays=${l_arg/keep=/}
            ;;
        tag=*)
            rman_tag=${l_arg/tag=/}
            ;;
        stb_only|prm_only|debug|nomail|dryrun)
            # all additional flags are put into gv_opt_flags variable
            # when needed, flags are checked with check_flag
            gv_opt_flags="${l_arg} ${gv_opt_flags}"
            ;;
        help|-h)
            usage
            ;;
        *)
            prn fatal "Unknown argument: ${l_arg}"
            ;;
        esac
    done

    # Validations:
    [[ -z ${gv_db_name}     ]] && { prn err "Database name was not specified"; usage; }
    [[ -z ${gv_backup_type} ]] && { prn err "Backup type was not specified"  ; usage; }

    case ${gv_backup_type} in
    lvl0|lvl1|arch|archdel)
        ;;
    *)
        prn err "Unknown backup type specified: ${gv_backup_type}"
        usage
        ;;
    esac

    if check_flag stb_only && check_flag prm_only ; then
        prn fatal "Options stb_only and prm_only are mutually exclusive."
    fi

    return 0
}

#-------------------------------------------------------------------------------
# Check if the optional flag is set
# Globals:
#    gv_opt_flags
# Parameters
#    1 - flag to check
#-------------------------------------------------------------------------------
check_flag() {
    local l_option="$1"
    echo "${gv_opt_flags}" | grep -q "${l_option}"
    return $?
}

#-------------------------------------------------------------------------------
# Cleanup temporary files
# Globals:
#    gv_lock_file
#    gv_rman_cmd_file
# Parameters:
#    none
#-------------------------------------------------------------------------------
cleanup() {
    [[ -f "${gv_lock_file}" ]]     && rm "${gv_lock_file}"
    [[ -f "${gv_rman_cmd_file}" ]] && rm "${gv_rman_cmd_file}"
    return 0
}

#-------------------------------------------------------------------------------
# Add header to the log file
# Globals:
#    gv_log_file
# Parameters:
#    none
#-------------------------------------------------------------------------------
log_header() {
    ( print_header; cat ${gv_log_file} ) > ${gv_log_file}.tmp
    mv ${gv_log_file}.tmp ${gv_log_file}
    return 0
}

################################################################################
# MAIN
################################################################################
main() {
    parse_args "$@"
    lockfile
    parse_cfg
    setenv
    init_log_file
    check_db_status
    check_db_role
    gen_rman_cmd
    print_header
    force_logging enable
    exec_rman
    force_logging disable
    log_header
    send_log
    cleanup
}

trap cleanup 1 2 15
main "$@"
