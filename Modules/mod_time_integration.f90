!------------------------------module of time integration--------------------------
module time_integration
    implicit none

    integer start_type  !Type of starting run (0 - from TS only, 1 - from the full checkpoint)

    integer(8) num_step,        &  !Number of time step during the run
               num_step_max        !The maximum number of time step for the run
    integer    init_year           !Initial year number for the run
    real(4) run_duration           !Duration of the run in days

    real(4) loc_data_tstep,        &  !Time step for writing  local data
            points_data_tstep,     &  !Time step for writing points data
            global_data_tstep,     &  !Time step for writing global data
            loc_data_wr_period,    &  !Period for writing local instantaneous data (in minutes; If >1440, then assumed 1440)
                                      !If <=0 then no local output is done
            points_data_wr_period, &  !Period for writing points data (in minutes; If >1440, then assumed 1440)
                                      !If <=0 then no local output is done
            global_data_wr_period     !Period for writing global data

    integer  loc_data_wr_period_step,        &   !period in steps to write local data
             points_data_wr_period_step,     &   !period in steps to write points
             global_data_wr_period_step,     &   !period in steps to write global data
             loc_data_nstep,                 &   !Number of record to write local data
             points_data_nstep,              &   !Number of record to write points
             global_data_nstep,              &   !Number of record to write global data
             nofcom                              !number of lines in "ocean_run.par" (calculated)

    integer key_write_local,      &      !Key for write local  data(1 - yes, 0 - no)
            key_write_global,     &      !Key for write global data(1 - yes, 0 - no)
            key_write_points             !Key for write points data(1 - yes, 0 - no)

    real(8) time_step,            &  !Model time step (in seconds)
            time_step_m,          &  !Model time step (in minutes)
            time_step_h,          &  !Model time step (in hours)
            time_step_d,          &  !Model time step (in days)
            seconds_of_day           !Current seconds of the day

    integer ndays_in_4yr(0:48),   &     !integer day distributions in 4-years (selected)
            ndays_noleap(0:48),   &     !integer day distributions in 4-years (without leap-year)
            ndays_leap  (0:48),   &     !integer day distributions in 4-years (with leap-year)
            m_sec_of_min,         &     !second counter in minute
            m_min_of_hour,        &     !minute counter in hour
            m_hour_of_day,        &     !hour counter in day
            m_day_of_month,       &     !day counter in month
            m_day_of_year,        &     !day counter in year
            m_day_of_4yr,         &     !day counter in 4-years
            m_month_of_year,      &     !mon counter in year
            m_month_of_4yr,       &     !mon counter in 4-years
            m_year_of_4yr,        &     !year counter in 4yrs
            m_day,                &     !model elapsed day counter starting from zero
            m_month,              &     !model elapsed month counter starting from zero
            m_year,               &     !year counter
            m_4yr,                &     !counter of 4-yr groups
            m_time_changed(7),    &     !change indicator of time
            key_time_print,       &     !key of printing time:0-not,1-print
            nstep_per_day


    include 'daydist.fi'  !day distribution in 4-year

    data ndays_noleap/ 0,  31,  59,  90, 120, 151, 181,   &    !1-st half year of 1-st year
                          212, 243, 273, 304, 334, 365,   &    !2-nd half year of 1-st year
                          396, 424, 455, 485, 516, 546,   &    !1-st half year of 2-nd year
                          577, 608, 638, 669, 699, 730,   &    !2-nd half year of 2-nd year
                          761, 789, 820, 850, 881, 911,   &    !1-st half year of 3-rd year
                          942, 973,1003,1034,1064,1095,   &    !2-nd half year of 3-rd year
                          1126,1154,1185,1215,1246,1276,   &    !1-st half year of 4-th year
                          1307,1338,1368,1399,1429,1460/        !2-nd half year of 4-th year

    data ndays_leap  / 0,  31,  59,  90, 120, 151, 181,   &    !1-st half year of 1-st year
                          212, 243, 273, 304, 334, 365,   &    !2-nd half year of 1-st year
                          396, 424, 455, 485, 516, 546,   &    !1-st half year of 2-nd year
                          577, 608, 638, 669, 699, 730,   &    !2-nd half year of 2-nd year
                          761, 789, 820, 850, 881, 911,   &    !1-st half year of 3-rd year
                          942, 973,1003,1034,1064,1095,   &    !2-nd half year of 3-rd year
                          1126,1155,1186,1216,1247,1277,   &    !1-st half year of 4-th year
                          1308,1339,1369,1400,1430,1461/        !2-nd half year of 4-th year

    !2-nd half year of 4-th year

    ! input parameters of task and names of files with input data
    character(256) comments(256)
    character(256) filepar,             &          !parameter file name
                   path2ocp,            &          !path to control points(results)
                   path2ocssdata,       &          !path to surface data on ocean grid
                   path2atmssdata,      &          !path to surface data on atm   grid
                   blank
    character(128) ss_ocfiles(8),         &          !files with sea surface data on oceanic grid
                   ss_ocfiles_fname(8),   &          !files with sea surface data on oceanic grid (fullnames)
                   ss_atmfiles(14),       &          !files with sea surface data on atmospheric grid
                   ss_atmfiles_fname(14), &          !files with sea surface data on atmospheric grid (fullnames)
                   atmask                            !file with atmospheric sea-land mask (1-land,0-ocean)

    integer year_loc,      &     !variables for writing local data
            mon_loc,       &
            day_loc,       &
            hour_loc,      &
            min_loc,       &
            nrec_loc

    integer year_global,      &     !variables for writing global data
            mon_global,       &
            day_global,       &
            hour_global,      &
            min_global,       &
            nrec_global
endmodule time_integration
!------------------------------end module of time integration--------------------------
