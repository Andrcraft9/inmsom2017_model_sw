module mpi_parallel_tools
    use hilbert_curve
    use mpi
    implicit none

    !include 'mpif.h'
    include "omp_lib.h"

    integer :: mod_decomposition
    character(128) :: file_decomposition
    integer :: bppnx, bppny
    integer :: parallel_dbg
    integer :: parallel_mod
    character(128) :: file_output

    integer :: nx_start, nx_end, ny_start, ny_end
    integer :: bnd_x1, bnd_x2, bnd_y1, bnd_y2

    type :: block2D
        real*8, dimension(:, :), pointer :: vals
    end type

    type :: block1D
        real*8, dimension(:), pointer :: vals
    end type

    integer, allocatable :: lbasins(:, :)

    ! There are two types of block numeration:
    !   Local:
    !       for each proc k = 1, ..., bcount. In custom order!
    !   Global:
    !       Cart coords of blocks (1, 1), ..., (bnx, bny)

    ! Cart grid of blocks
    integer :: bnx, bny
    ! Map: block coords to proc
    ! If bglob_proc(m, n) == -1 => (m, n) block is land-block!
    integer, allocatable :: bglob_proc(:, :)

    integer :: bcount
    ! Total blocks for computational
    integer :: total_blocks
    ! Map: local block number to block coords
    integer, allocatable :: bindx(:, :)
    ! significant point area in blocks, local block numeration
    integer, allocatable :: bnx_start(:), bnx_end(:),    &
                            bny_start(:), bny_end(:)
    ! array boundary in blocks, local block numeration
    integer, allocatable :: bbnd_x1(:), bbnd_x2(:),  &
                            bbnd_y1(:), bbnd_y2(:)

    ! Proc grid information
    integer :: rank, procs
    integer :: cart_comm
    integer, dimension(2) :: p_size, p_coord
    logical, dimension(2) :: p_period

    ! MPI buffers
    integer, allocatable :: reqsts(:), statuses(:, :)
    type(block1D), dimension(:), pointer :: sync_buf8_send_nyp, sync_buf8_recv_nyp
    type(block1D), dimension(:), pointer :: sync_buf8_send_nxp, sync_buf8_recv_nxp
    type(block1D), dimension(:), pointer :: sync_buf8_send_nym, sync_buf8_recv_nym
    type(block1D), dimension(:), pointer :: sync_buf8_send_nxm, sync_buf8_recv_nxm
    real*8, allocatable :: sync_edge_buf8_recv_nxp_nyp(:)
    real*8, allocatable :: sync_edge_buf8_recv_nxp_nym(:)
    real*8, allocatable :: sync_edge_buf8_recv_nxm_nyp(:)
    real*8, allocatable :: sync_edge_buf8_recv_nxm_nym(:)

    ! Timers
    real*8 :: time_barotrop
    real*8 :: time_model_step, time_output
    real*8 :: time_sync

contains

    subroutine parallel_check_err(err)
        implicit none

        integer :: err, totalerr
        integer :: ierr

        call mpi_allreduce(err, totalerr, 1, mpi_integer,  &
                           mpi_sum, cart_comm, ierr)
        if (totalerr >= 1) then
            if (rank .eq. 0) print *, 'Error! ABORT PROGRAM!'
            call parallel_finalize
            stop
        endif
    end subroutine

    subroutine parallel_init()
        use rwpar_routes
        implicit none

        integer :: count_threads, num_thread
        integer :: ierr, rank_cart
        integer :: nofcom
        character(128) :: comments(128)

        call mpi_init(ierr)
        call mpi_comm_rank(mpi_comm_world, rank, ierr)
        if (rank .eq. 0) then
            print *, 'Read parallel.par...'
            call readpar('parallel.par', comments, nofcom)
            read(comments(1),*) mod_decomposition
            call get_first_lexeme(comments(2), file_decomposition)
            read(comments(3),*) bppnx
            read(comments(4),*) bppny
            read(comments(5),*) parallel_dbg
            read(comments(6),*) parallel_mod
            call get_first_lexeme(comments(7), file_output)

            print *, 'mod_decomposition=', mod_decomposition
            print *, 'decomposition file:', file_decomposition
            print *, 'bppnx=', bppnx
            print *, 'bppny=', bppny
            print *, 'parallel_dbg=', parallel_dbg
            print *, 'parallel_mod=', parallel_mod
            print *, 'output file:', file_output
        endif

        call mpi_bcast(file_decomposition, 128, mpi_character, 0, mpi_comm_world, ierr)
        call mpi_bcast(mod_decomposition, 1, mpi_integer, 0, mpi_comm_world, ierr)
        call mpi_bcast(bppnx, 1, mpi_integer, 0, mpi_comm_world, ierr)
        call mpi_bcast(bppny, 1, mpi_integer, 0, mpi_comm_world, ierr)
        call mpi_bcast(parallel_dbg, 1, mpi_integer, 0, mpi_comm_world, ierr)
        call mpi_bcast(parallel_mod, 1, mpi_integer, 0, mpi_comm_world, ierr)
        call mpi_bcast(file_output, 128, mpi_character, 0, mpi_comm_world, ierr)

        !if (rank .eq. 0) then
        !    if (.not. MPI_SUBARRAYS_SUPPORTED) then
        !        print *, 'MPI_SUBARRAYS_SUPPORTED = FALSE'
        !    endif
        !endif

        p_period = (/.true., .true./)
        p_size = (/0,0/)
        ierr = 0
        call mpi_comm_size(mpi_comm_world, procs, ierr)
        call mpi_dims_create(procs, 2, p_size, ierr)
        call mpi_cart_create(mpi_comm_world, 2, p_size, p_period, .false., cart_comm, ierr)
        call mpi_cart_coords(cart_comm, rank, 2, p_coord, ierr)

        call mpi_comm_rank(cart_comm, rank_cart, ierr)

        print *, 'rank_world, rank_cart and cord:', rank, rank_cart, p_coord
        call mpi_barrier(cart_comm, ierr)

        !$omp parallel
        count_threads = omp_get_num_threads()
        num_thread = omp_get_thread_num()
        if (num_thread .eq. 0) print *, "OMP Threads: ", count_threads
        !$omp end parallel
        call mpi_barrier(cart_comm, ierr)
    end subroutine

    subroutine parallel_finalize
        implicit none

        integer :: k, ierr

        if (allocated(bnx_start)) deallocate(bnx_start)
        if (allocated(bnx_end)) deallocate(bnx_end)
        if (allocated(bny_start)) deallocate(bny_start)
        if (allocated(bny_end)) deallocate(bny_end)

        if (allocated(bbnd_x1)) deallocate(bbnd_x1)
        if (allocated(bbnd_x2)) deallocate(bbnd_x2)
        if (allocated(bbnd_y1)) deallocate(bbnd_y1)
        if (allocated(bbnd_y2)) deallocate(bbnd_y2)

        if (allocated(bindx)) deallocate(bindx)
        if (allocated(bglob_proc)) deallocate(bglob_proc)
        if (allocated(lbasins)) deallocate(lbasins)

        ! MPI buffers
        if (allocated(reqsts)) then
            deallocate(reqsts)
            deallocate(statuses)

            !if (allocated(sync_buf8_send_nyp)) then
            do k = 1, bcount
                deallocate(sync_buf8_send_nyp(k)%vals, sync_buf8_recv_nyp(k)%vals)
                deallocate(sync_buf8_send_nxp(k)%vals, sync_buf8_recv_nxp(k)%vals)
                deallocate(sync_buf8_send_nym(k)%vals, sync_buf8_recv_nym(k)%vals)
                deallocate(sync_buf8_send_nxm(k)%vals, sync_buf8_recv_nxm(k)%vals)
            enddo
            deallocate(sync_buf8_send_nyp, sync_buf8_recv_nyp)
            deallocate(sync_buf8_send_nxp, sync_buf8_recv_nxp)
            deallocate(sync_buf8_send_nym, sync_buf8_recv_nym)
            deallocate(sync_buf8_send_nxm, sync_buf8_recv_nxm)

            deallocate(sync_edge_buf8_recv_nxp_nyp)
            deallocate(sync_edge_buf8_recv_nxp_nym)
            deallocate(sync_edge_buf8_recv_nxm_nyp)
            deallocate(sync_edge_buf8_recv_nxm_nym)
            !endif
            !if (allocated(sync_buf8_send_nyp)) deallocate(sync_buf8_send_nyp)
            !if (allocated(sync_buf8_recv_nyp)) deallocate(sync_buf8_recv_nyp)
        endif

        call mpi_finalize(ierr)
    end subroutine

    subroutine set_block_boundary(k)
        implicit none

        integer :: k

        nx_start = bnx_start(k); nx_end = bnx_end(k)
        ny_start = bny_start(k); ny_end = bny_end(k)

        bnd_x1 = bbnd_x1(k); bnd_x2 = bbnd_x2(k)
        bnd_y1 = bbnd_y1(k); bnd_y2 = bbnd_y2(k)

    end subroutine

    subroutine parallel_read_mask(ftemask)
        use main_basin_pars
        use rec_length
        implicit none

        character*(*) ftemask
        character frmt*16,comment*80
        integer :: m, n, ierr

        write(frmt,1000) nx
1000    format('(',i9,'i1)')

        allocate(lbasins(nx, ny))
        ! reading mask from:
        if (rank .eq. 0) then
            open(11, file=ftemask, status='old', recl=nx*lrecl)
            read(11, '(a)') comment(1:min(80,nx))
            if (rank .eq. 0) write(*,'(1x,a)') comment
            do n = ny, 1, -1
                read(11, frmt, end=99) (lbasins(m,n),m=1,nx)
            enddo
            close(11)
        endif
        call mpi_bcast(lbasins, nx*ny, mpi_integer, 0, cart_comm, ierr)

        return
99      write(*,*) 'error in reading file', ftemask(1:len_trim(ftemask))
        stop 1
    end subroutine

    subroutine parallel_blocks_distribution()
        use main_basin_pars
        implicit none

        real*8, allocatable :: bglob_weight(:, :)
        real*8 :: bweight, max_bweight

        integer, allocatable :: glob_bnx_start(:, :), glob_bnx_end(:, :),    &
                                glob_bny_start(:, :), glob_bny_end(:, :)
        integer, allocatable :: glob_bbnd_x1(:, :), glob_bbnd_x2(:, :),  &
                                glob_bbnd_y1(:, :), glob_bbnd_y2(:, :)

        integer :: m, n, i, j, k, locn
        integer :: land_blocks
        integer :: bshared
        real*8 :: bcomm_metric, max_bcomm_metric
        integer, dimension(2) :: kblock
        integer :: ierr

        ! Set Cart grid of blocks
        bnx = bppnx * p_size(1)
        bny = bppny * p_size(2)

        if (rank == 0) print *, "PARALLEL BLOCKS DISTRIBUTION WITH MOD:", mod_decomposition
        if (rank == 0) print *, 'bnx, bny and Total blocks:', bnx, bny, bnx*bny
        if (rank == 0) print *, 'pnx, pny and procs:', p_size(1), p_size(2), procs
        call mpi_barrier(cart_comm, ierr)

        ! Check bnx and bny
        ierr = 0
        if (mod(bnx, p_size(1)) /= 0) then
            print *, 'Error in bnx! mod(bnx, p_size(1)) /= 0 !...'
            ierr = 1
        endif
        if (mod(bny, p_size(2)) /= 0) then
            print *, 'Error in bny! mod(bny, p_size(2)) /= 0 !...'
            ierr = 1
        endif
        call parallel_check_err(ierr)

        allocate(bglob_weight(bnx, bny))
        allocate(glob_bnx_start(bnx, bny), glob_bnx_end(bnx, bny),     &
                 glob_bny_start(bnx, bny), glob_bny_end(bnx, bny))
        allocate(glob_bbnd_x1(bnx, bny), glob_bbnd_x2(bnx, bny),       &
                 glob_bbnd_y1(bnx, bny), glob_bbnd_y2(bnx, bny))

        glob_bnx_start = 0; glob_bnx_end = 0; glob_bny_start = 0; glob_bny_end = 0
        glob_bbnd_x1 = 0; glob_bbnd_x2 = 0; glob_bbnd_y1 = 0; glob_bbnd_y2 = 0
        bweight = 0
        bglob_weight = 0.0d0

        land_blocks = 0
        do m = 1, bnx
            do n = 1, bny
                locn = floor(real(nx - 4)/real(bnx))
                glob_bnx_start(m, n) = locn*(m-1) + 1 + 2
                if (m .eq. bnx) then
                    locn = (nx - 2) - glob_bnx_start(m, n) + 1
                endif
                glob_bnx_end(m, n) = glob_bnx_start(m, n) + locn - 1
                glob_bnx_start(m, n) = glob_bnx_start(m, n)
                ! border area
                glob_bbnd_x1(m, n) = glob_bnx_start(m, n) - 2
                glob_bbnd_x2(m, n) = glob_bnx_end(m, n) + 2

                locn = floor(real(ny - 4)/real(bny))
                glob_bny_start(m, n) = locn*(n-1) + 1 + 2
                if (n .eq. bny) then
                    locn = (ny - 2) - glob_bny_start(m, n) + 1
                endif
                glob_bny_end(m, n) = glob_bny_start(m, n) + locn - 1
                glob_bny_start(m, n) = glob_bny_start(m, n)
                ! border area
                glob_bbnd_y1(m, n) = glob_bny_start(m, n) - 2
                glob_bbnd_y2(m, n) = glob_bny_end(m, n) + 2

                ! Compute load-balance
                do i = glob_bnx_start(m, n), glob_bnx_end(m, n)
                    do j = glob_bny_start(m, n), glob_bny_end(m, n)
                        bglob_weight(m, n) = bglob_weight(m, n) + (1.0d0 - real(lbasins(i, j)))
                    enddo
                enddo
                ! Only-land blocks
                if (bglob_weight(m, n) == 0.0d0) then
                    land_blocks = land_blocks + 1
                endif
            enddo
        enddo
        if (rank == 0) print *, "Total land blocks:", land_blocks

        if (bnx*bny - land_blocks < procs) then
            if (rank == 0) print *, 'procs > computational-blocks... Error!'
            ierr = 1
        endif
        call parallel_check_err(ierr)

        ! Compute bglob_proc
        allocate(bglob_proc(bnx, bny))
        if (mod_decomposition == 0) then
            if (rank == 0) print *, "Uniform blocks decomposition!..."
            call parallel_uniform_decomposition(bglob_proc, bglob_weight, bnx, bny)
        elseif (mod_decomposition == 1) then
            if (rank == 0) print *, "Load-Balancing blocks decomposition with using Hilbert curve!..."
            call parallel_hilbert_curve_decomposition(bglob_proc, bglob_weight, bnx, bny, land_blocks)
        elseif (mod_decomposition == 2) then
            if (rank == 0) print *, "Decomposition from file!..."
            call parallel_file_decomposition(bglob_proc, bglob_weight, bnx, bny)
        else
            if (rank == 0) print *, "Unknown mode!"
            call mpi_abort(cart_comm, 1, ierr)
            stop   
        endif

        ! Debug Output
        if (parallel_dbg >= 1) then
            if (rank == 0) then
                open(90, file = file_output)
                write(90, *)  bnx, bny, p_size(1), p_size(2)
                do m = 1, bnx
                    do n = 1, bny
                        write(90, *) m, n, bglob_proc(m, n), bglob_weight(m, n)
                    enddo 
                enddo
                !call flush()
                close(90)
            endif
            call mpi_barrier(cart_comm, ierr)
        endif

        ! Compute blocks per proc
        bcount = 0; bweight = 0.0d0
        do m = 1, bnx
            do n = 1, bny
                if (bglob_proc(m, n) == rank) then
                    bcount = bcount + 1
                    bweight = bweight + bglob_weight(m, n)
                endif
            enddo
        enddo
        call mpi_allreduce(bcount, total_blocks, 1, mpi_integer, mpi_sum, cart_comm, ierr)
        call mpi_allreduce(bweight, max_bweight, 1, mpi_real8, mpi_max, cart_comm, ierr)

        ierr = 0
        if (bcount <= 0) then
            print *, rank, 'Proc with only land-blocks... Error!'
            ierr = 1
        endif
        call parallel_check_err(ierr)

        ! Print information about blocks
        if (rank == 0) print *, 'Total blocks:', total_blocks, 'LB: ', max_bweight / (sum(bglob_weight) / real(procs))
        call mpi_barrier(cart_comm, ierr)
        if (parallel_dbg >= 2) then
            print *, rank, 'Blocks per proc:', bcount, 'Weight per proc:', bweight !/ ((nx-4)*(ny-4))
            call mpi_barrier(cart_comm, ierr)
        endif

        ! Allocate blocks arrays per proc
        allocate(bindx(bcount, 2))
        allocate(bnx_start(bcount), bnx_end(bcount),     &
                 bny_start(bcount), bny_end(bcount))
        allocate(bbnd_x1(bcount), bbnd_x2(bcount),       &
                 bbnd_y1(bcount), bbnd_y2(bcount))
        bindx = 0
        bnx_start = 0; bnx_end = 0; bny_start = 0; bny_end = 0
        bbnd_x1 = 0; bbnd_x2 = 0; bbnd_y1 = 0; bbnd_y2 = 0

        k = 1
        do m = 1, bnx
            do n = 1, bny
                if (bglob_proc(m, n) == rank) then
                    ! Map local block numeration to block coords
                    bindx(k, 1) = m
                    bindx(k, 2) = n

                    bnx_start(k) = glob_bnx_start(m, n)
                    bnx_end(k) = glob_bnx_end(m, n)
                    bny_start(k) = glob_bny_start(m, n)
                    bny_end(k) = glob_bny_end(m, n)

                    bbnd_x1(k) = glob_bbnd_x1(m, n)
                    bbnd_x2(k) = glob_bbnd_x2(m, n)
                    bbnd_y1(k) = glob_bbnd_y1(m, n)
                    bbnd_y2(k) = glob_bbnd_y2(m, n)

                    k = k + 1
                endif
            enddo
        enddo

        call allocate_mpi_buffers()

        ! Addition metric (communication metric)
        bshared = 0
        do k = 1, bcount
            m =  bindx(k, 1)
            n =  bindx(k, 2)
            
            kblock(1) = m - 1; kblock(2) = n
            call check_block_status(kblock, i)
            if (i /= rank) then
                bshared = bshared + 1
                cycle
            endif
            
            kblock(1) = m + 1; kblock(2) = n
            call check_block_status(kblock, i)
            if (i /= rank) then
                bshared = bshared + 1
                cycle
            endif
            
            kblock(1) = m; kblock(2) = n - 1
            call check_block_status(kblock, i)
            if (i /= rank) then
                bshared = bshared + 1
                cycle
            endif
            
            kblock(1) = m; kblock(2) = n + 1
            call check_block_status(kblock, i)
            if (i /= rank) then
                bshared = bshared + 1
                cycle
            endif
        enddo
        bcomm_metric = dble(bshared) / dble(bcount) 
        call mpi_allreduce(bcomm_metric, max_bcomm_metric, 1, mpi_real8, mpi_max, cart_comm, ierr)
        if (rank == 0) print *, 'Partition quality:', max_bcomm_metric
        call mpi_barrier(cart_comm, ierr)
        if (parallel_dbg >= 2) then
            print *, rank, 'bcomm_metric', bcomm_metric
            call mpi_barrier(cart_comm, ierr)
        endif

        deallocate(bglob_weight)
        deallocate(glob_bnx_start, glob_bnx_end, glob_bny_start, glob_bny_end)
        deallocate(glob_bbnd_x1, glob_bbnd_x2, glob_bbnd_y1, glob_bbnd_y2)

    end subroutine

    subroutine parallel_uniform_decomposition(bgproc, bgweight, bnx, bny)
        implicit none

        integer :: bnx, bny
        integer :: bgproc(bnx, bny)
        real*8 :: bgweight(bnx, bny)

        integer :: m, n, ierr
        integer :: loc_bnx, loc_bny
        integer :: xblock_start, yblock_start
        integer, allocatable :: buf_int(:, :)

        loc_bnx = bnx / p_size(1)
        loc_bny = bny / p_size(2)
        !bcount = loc_bnx*loc_bny
        !if (parallel_dbg >= 1) print *, rank, 'loc_bnx, loc_bny and Blocks per proc: ', loc_bnx, loc_bny, bcount
        !call mpi_barrier(cart_comm, ierr)

        xblock_start = 1 + p_coord(1)*loc_bnx
        yblock_start = 1 + p_coord(2)*loc_bny
        !if (parallel_dbg >= 2) print *, rank, 'xb_start, yb_start', xblock_start, yblock_start
        !call mpi_barrier(cart_comm, ierr)
        bgproc = -1
        do m = xblock_start, xblock_start + loc_bnx - 1
            do n = yblock_start, yblock_start + loc_bny - 1
                bgproc(m, n) = rank
                if (bgweight(m, n) == 0.0d0) then
                    bgproc(m, n) = -1
                endif
            enddo
        enddo
        ! Sync bglob_proc array
        allocate(buf_int(bnx, bny))
        buf_int = bgproc + 1
        call mpi_allreduce(buf_int, bgproc, bnx*bny, mpi_integer, mpi_sum, cart_comm, ierr)
        bgproc = bgproc - 1

        if (parallel_dbg >= 3) then
            call parallel_int_output(bgproc, 1, bnx, 1, bny, 'bglob_proc from uniform decomposition')
        endif

        deallocate(buf_int)

    end subroutine

    subroutine parallel_hilbert_curve_decomposition(bgproc, bgweight, bnx, bny, land_blocks)
        implicit none

        integer :: bnx, bny
        integer :: land_blocks
        integer :: bgproc(bnx, bny)
        real*8 :: bgweight(bnx, bny)

        integer :: k, i, ierr
        integer :: hilbert_index, hilbert_coord_x, hilbert_coord_y
        integer :: ks, sea_blocks
        real*8 :: weight, tot_weight, mean_weight, last_weight

        hilbert_index = int(log(real(bnx))/ log(2.0))
        ierr = 0
        if (bnx /= bny) then
            if (rank == 0) print *, 'bnx not equal to bny! Can`t build Hilbert curve for this geometry!'
            ierr = 1
        endif
        if (2**hilbert_index /= bnx) then
            if (rank == 0) print *, '2**M not eqal to bnx! Can`t build Hilbert curve for this geometry!'
            ierr = 1
        endif
        call parallel_check_err(ierr)

        if (rank == 0) print *, 'Hilbert curve index:', hilbert_index

        tot_weight = sum(bgweight)
        mean_weight = tot_weight / procs
        sea_blocks = bnx*bny - land_blocks

        if (parallel_dbg >= 1) then
            if (rank == 0 ) print *, 'Total blocks weigth:', tot_weight, "Mean blocks weigth:", mean_weight
        endif

        weight = 0.0d0
        last_weight = 0.0d0
        i = 0; ks = 0
        do k = 1, bnx*bny
            call hilbert_d2xy(hilbert_index, k-1, hilbert_coord_x, hilbert_coord_y)
            hilbert_coord_x = hilbert_coord_x + 1; hilbert_coord_y = hilbert_coord_y + 1
            
            ! Skip land blocks
            if (bgweight(hilbert_coord_x, hilbert_coord_y) == 0.0d0) then
                bgproc(hilbert_coord_x, hilbert_coord_y) = -1
                cycle
            else
                ks = ks + 1
            endif

            weight = weight + bgweight(hilbert_coord_x, hilbert_coord_y)
            
            !if (sea_blocks - ks >= procs - i - 1) then
                if (weight + (weight - bgweight(hilbert_coord_x, hilbert_coord_y)) > 2.0*mean_weight) then
                    ! Recompute mean value
                    mean_weight = (tot_weight - last_weight) / (procs - i - 1)
                    ! Go to next proc
                    i = i + 1
                    weight = bgweight(hilbert_coord_x, hilbert_coord_y)
                    if (i > procs-1) then
                        i = procs-1
                        !if (rank == 0 .and. parallel_dbg < 2) print *, 'Warning! Last procs ...'
                        if (rank == 0) print *, k, 'Warning! Last procs ...'
                    endif
                endif
            !else
            !    i = i + 1
            !    weight = bgweight(hilbert_coord_x, hilbert_coord_y)
            !endif

            bgproc(hilbert_coord_x, hilbert_coord_y) = i
            last_weight = last_weight + bgweight(hilbert_coord_x, hilbert_coord_y)
        enddo

        if (parallel_dbg >= 3) then
            call parallel_int_output(bgproc, 1, bnx, 1, bny, 'bglob_proc from load-balanced hilbert curve decomposition')
        endif

    end subroutine

    subroutine parallel_file_decomposition(bgproc, bgweight, bnx, bny)
        implicit none

        integer :: bnx, bny
        integer :: bgproc(bnx, bny)
        real*8 :: bgweight(bnx, bny)
        integer :: file_bnx, file_bny, file_pnx, file_pny
        integer :: k, m, n, bgp, ierr
        real*8 :: bgw
       
        if (rank == 0) then 
            open(90, file=file_decomposition, status='old')
            read(90,*) file_bnx, file_bny, file_pnx, file_pny

            if (file_bnx /= bnx .or. file_bny /= bny) then
                if (rank == 0) print *, 'incorrect bnx or bny in decomposition file!'
                call mpi_abort(cart_comm, 1, ierr)
                stop    
            endif
            if (file_pnx /= p_size(1) .or. file_pny /= p_size(2)) then
                if (rank == 0) print *, 'incorrect pnx or pny in decomposition file!'
                call mpi_abort(cart_comm, 1, ierr)
                stop    
            endif
            do k = 1, bnx*bny
                read(90,*) m, n, bgp, bgw
                bgproc(m, n) = bgp
                bgweight(m, n) = bgw
            enddo
            close(90)
        endif
        call mpi_bcast(bgproc, bnx*bny, mpi_integer, 0, cart_comm, ierr)
        call mpi_bcast(bgweight, bnx*bny, mpi_real8, 0, cart_comm, ierr)

        if (parallel_dbg >= 3) then
            call parallel_int_output(bgproc, 1, bnx, 1, bny, 'bglob_proc from file decomposition')
        endif

    end subroutine

    subroutine allocate_mpi_buffers
        implicit none

        integer :: k, nx_dir_size, ny_dir_size

        allocate(sync_buf8_send_nyp(bcount), sync_buf8_recv_nyp(bcount))
        allocate(sync_buf8_send_nxp(bcount), sync_buf8_recv_nxp(bcount))
        allocate(sync_buf8_send_nym(bcount), sync_buf8_recv_nym(bcount))
        allocate(sync_buf8_send_nxm(bcount), sync_buf8_recv_nxm(bcount))
        do k = 1, bcount
            ny_dir_size = bnx_end(k) - bnx_start(k) + 1
            nx_dir_size = bny_end(k) - bny_start(k) + 1
            allocate(sync_buf8_send_nyp(k)%vals(ny_dir_size), sync_buf8_recv_nyp(k)%vals(ny_dir_size))
            allocate(sync_buf8_send_nxp(k)%vals(nx_dir_size), sync_buf8_recv_nxp(k)%vals(nx_dir_size))
            allocate(sync_buf8_send_nym(k)%vals(ny_dir_size), sync_buf8_recv_nym(k)%vals(ny_dir_size))
            allocate(sync_buf8_send_nxm(k)%vals(nx_dir_size), sync_buf8_recv_nxm(k)%vals(nx_dir_size))
        enddo

        allocate(sync_edge_buf8_recv_nxp_nyp(bcount))
        allocate(sync_edge_buf8_recv_nxp_nym(bcount))
        allocate(sync_edge_buf8_recv_nxm_nyp(bcount))
        allocate(sync_edge_buf8_recv_nxm_nym(bcount))

        allocate(reqsts(2*8*bcount), statuses(MPI_STATUS_SIZE, 2*8*bcount))
    end subroutine

    subroutine parallel_int_output(arr, x1, x2, y1, y2, msg)
        implicit none

        integer :: x1, x2, y1, y2
        integer :: arr(x1:x2, y1:y2)
        character*(*) msg
        integer :: k, m, n, ierr

        if (rank .eq. 0) print *, msg
        call mpi_barrier(cart_comm, ierr)

        do k = 0, procs-1
            if (rank .eq. k) then
                print *, rank
                do m = x1, x2
                    do n = y1, y2
                        print *, rank, 'm, n, a(m, n)', m, n, arr(m, n)
                    enddo
                enddo
            endif
            call mpi_barrier(cart_comm, ierr)
        enddo

    end subroutine

    subroutine allocate_block2D(blks, val)
        implicit none

        type(block2D), dimension(:), pointer :: blks
        real*8 :: val
        integer :: k

        allocate(blks(bcount))
        do k = 1, bcount
            allocate(blks(k)%vals(bbnd_x1(k):bbnd_x2(k), bbnd_y1(k):bbnd_y2(k)))
            blks(k)%vals = val
        enddo
    end subroutine

    subroutine deallocate_blocks2D(blks)
        implicit none

        type(block2D), dimension(:), pointer :: blks
        integer :: k

        do k = 1, bcount
            deallocate(blks(k)%vals)
        enddo
        deallocate(blks)
    end subroutine

    subroutine init_times
        implicit none
        time_model_step = 0.0d0
        time_barotrop = 0.0d0
        time_sync = 0.0d0
        time_output = 0.0d0
        return
    end subroutine

    subroutine print_times
        implicit none
        if (rank .eq. 0) then
            print *, "Time model step: ", time_model_step
            print *, "Time barotropic: ", time_barotrop
            print *, "Time sync: ", time_sync
            print *, "Time output: ", time_output
        endif
        return
    end subroutine

    subroutine start_timer(time)
        implicit none

        real*8, intent(inout) :: time

        time = mpi_wtime()
        return
    end subroutine

    subroutine end_timer(time)
        implicit none

        real*8, intent(inout) :: time
        real*8 :: outtime
        integer :: ierr

        time = mpi_wtime() - time
        call mpi_allreduce(time, outtime, 1, mpi_real8,      &
                           mpi_max, cart_comm, ierr)
        time = outtime
        return
    end subroutine

    integer function get_local_block_number(m, n)
        implicit none

        integer :: m, n
        integer :: k

        get_local_block_number = -1
        do k = 1, bcount
            if (m == bindx(k, 1) .and. n == bindx(k, 2)) then
                get_local_block_number = k
                exit
            endif
        enddo

        return
    end function


!    subroutine irecv_real8(k, src_block, blks, tag, dx1, dx2, dy1, dy2, reqst, stat)
!        implicit none
!        integer :: p_src, k, tag
!        integer, dimension(2) :: src_block
!        type(block2D), dimension(:), pointer :: blks
!        integer :: dx1, dx2, dy1, dy2
!        integer :: reqst, stat
!        integer :: ierr, flg_recv
!        integer, dimension(2) :: bgrid
                !call mpi_irecv(blks(k)%vals(dx1:dx2, dy1:dy2), (dx2 - dx1 + 1)*(dy2 - dy1 + 1), &
!                                             mpi_real8, p_src, tag, cart_comm, reqst, ierr)

    subroutine irecv_real8(k, src_block, src_proc, buff, buff_size, tag, reqst)
        implicit none
        integer, dimension(2) :: src_block
        integer :: k, src_proc, tag
        integer :: buff_size
        real*8 :: buff(:)
        integer :: reqst
        integer :: ierr

        if (parallel_dbg >= 4) print *, rank, 'IRECV. block: ', bindx(k, 1), bindx(k, 2), 'src_block:', src_block(1), src_block(2), 'src_p:', src_proc, 'tag', tag
        !call mpi_irecv(blks(k)%vals(dx1:dx2, dy1:dy2), (dx2 - dx1 + 1)*(dy2 - dy1 + 1), &
        !               mpi_real8, p_src, tag, cart_comm, reqst, ierr)
        call mpi_irecv(buff, buff_size, mpi_real8, src_proc, tag, cart_comm, reqst, ierr)

    end subroutine

    subroutine isend_real8(k, dist_block, dist_proc, buff, buff_size, tag, reqst)
        implicit none

        integer, dimension(2) :: dist_block
        integer :: k, dist_proc, tag
        integer :: buff_size
        real*8 :: buff(:)
        integer :: reqst
        integer :: ierr

        if (parallel_dbg >= 4) print *, rank, 'ISEND. block: ', bindx(k, 1), bindx(k, 2), 'dst_block:', dist_block(1), dist_block(2), 'dst_p:', dist_proc, 'tag', tag
        !call mpi_isend(blks(k)%vals(sx1:sx2, sy1:sy2), (sx2 - sx1 + 1)*(sy2 - sy1 + 1), &
        !               mpi_real8, p_dist, tag, cart_comm, reqst, ierr)
        call mpi_isend(buff, buff_size, mpi_real8, dist_proc, tag, cart_comm, reqst, ierr)

    end subroutine

    subroutine check_block_status(b_coords, p)
        implicit none

        integer, dimension(2), intent(in) :: b_coords
        integer, intent(out) :: p
        integer, dimension(2) :: bgrid

        bgrid(1) = bnx; bgrid(2) = bny
        if (check_cart_coord(b_coords - 1, bgrid) /= 1) then
            ! Out of range, block does not exist
            p = -2
            return
        endif

        p = bglob_proc(b_coords(1), b_coords(2))
        return

    end subroutine

    subroutine syncborder_block2D(blks)
        implicit none

        type(block2D), dimension(:), pointer :: blks
        integer :: k, lock, bm, bn, reqst
        integer, dimension(2) :: src_block, dist_block
        integer :: src_p, dist_p
        integer :: send_size, recv_size
        integer :: ierr
        integer :: tag, icount

        icount = 1

        ! Non-blocking Recv calls
        do k = 1, bcount
            bm = bindx(k, 1)
            bn = bindx(k, 2)

            ! irecv in ny+
            src_block(1) = bm; src_block(2) = bn - 1
            !tag = src_block(2) + (src_block(1) - 1)*bnx
            tag = 10*(src_block(2) + (src_block(1) - 1)*bnx) + 1
            call check_block_status(src_block, src_p)
            if (src_p >= 0) then
                if (src_p /= rank) then
                    recv_size = bnx_end(k) - bnx_start(k) + 1
                    call irecv_real8(k, src_block, src_p, sync_buf8_recv_nyp(k)%vals, recv_size, tag, reqst)
                    !call irecv_real8(k, src_block, src_p, blks(k)%vals(bnx_start(k):bnx_end(k), bbnd_y1(k) + 1), recv_size, bn, reqst)
                    reqsts(icount) = reqst
                    icount = icount + 1
                endif
            endif
            ! irecv in nx+
            src_block(1) = bm - 1; src_block(2) = bn
            !tag = src_block(2) + (src_block(1) - 1)*bnx
            tag = 10*(src_block(2) + (src_block(1) - 1)*bnx) + 2
            call check_block_status(src_block, src_p)
            if (src_p >= 0) then
                if (src_p /= rank) then
                    recv_size = bny_end(k) - bny_start(k) + 1
                    call irecv_real8(k, src_block, src_p, sync_buf8_recv_nxp(k)%vals, recv_size, tag, reqst)
                    !call irecv_real8(k, src_block, src_p, blks(k)%vals(bbnd_x1(k) + 1, bny_start(k):bny_end(k)), recv_size, bn, reqst)
                    reqsts(icount) = reqst
                    icount = icount + 1
                endif
            endif
            ! irecv in ny-
            src_block(1) = bm; src_block(2) = bn + 1
            !tag = src_block(2) + (src_block(1) - 1)*bnx
            tag = 10*(src_block(2) + (src_block(1) - 1)*bnx) + 3
            call check_block_status(src_block, src_p)
            if (src_p >= 0) then
                if (src_p /= rank) then
                    recv_size = bnx_end(k) - bnx_start(k) + 1
                    call irecv_real8(k, src_block, src_p, sync_buf8_recv_nym(k)%vals, recv_size, tag, reqst)
                    !call irecv_real8(k, src_block, src_p, blks(k)%vals(bnx_start(k):bnx_end(k), bbnd_y2(k) - 1), recv_size, bn, reqst)
                    reqsts(icount) = reqst
                    icount = icount + 1
                endif
            endif
            ! irecv in nx-
            src_block(1) = bm + 1; src_block(2) = bn
            !tag = src_block(2) + (src_block(1) - 1)*bnx
            tag = 10*(src_block(2) + (src_block(1) - 1)*bnx) + 4
            call check_block_status(src_block, src_p)
            if (src_p >= 0) then
                if (src_p /= rank) then
                    recv_size = bny_end(k) - bny_start(k) + 1
                    call irecv_real8(k, src_block, src_p, sync_buf8_recv_nxm(k)%vals, recv_size, tag, reqst)
                    !call irecv_real8(k, src_block, src_p, blks(k)%vals(bbnd_x2(k) - 1, bny_start(k):bny_end(k)), recv_size, bn, reqst)
                    reqsts(icount) = reqst
                    icount = icount + 1
                endif
            endif

            !----------------------------Edge points----------------------------!
            ! Edge irecv in nx+ ny+
            src_block(1) = bm - 1; src_block(2) = bn - 1
            !tag = 10*(src_block(2) + (src_block(1) - 1)*bnx)
            tag = 10*(src_block(2) + (src_block(1) - 1)*bnx) + 5
            call check_block_status(src_block, src_p)
            if (src_p >= 0) then
                if (src_p /= rank) then
                    call mpi_irecv(sync_edge_buf8_recv_nxp_nyp(k), 1, mpi_real8, src_p, tag, cart_comm, reqst, ierr)
                    if (parallel_dbg >= 5) print *, rank, 'IRECV EDGE. block: ', bindx(k, 1), bindx(k, 2), 'src_block:', src_block(1), src_block(2), 'src_p:', src_p, 'tag', tag
                    reqsts(icount) = reqst
                    icount = icount + 1
                endif
            endif
            ! Edge irecv in nx+ ny-
            src_block(1) = bm - 1; src_block(2) = bn + 1
            !tag = 10*(src_block(2) + (src_block(1) - 1)*bnx)
            tag = 10*(src_block(2) + (src_block(1) - 1)*bnx) + 6
            call check_block_status(src_block, src_p)
            if (src_p >= 0) then
                if (src_p /= rank) then
                    call mpi_irecv(sync_edge_buf8_recv_nxp_nym(k), 1, mpi_real8, src_p, tag, cart_comm, reqst, ierr)
                    if (parallel_dbg >= 5) print *, rank, 'IRECV EDGE. block: ', bindx(k, 1), bindx(k, 2), 'src_block:', src_block(1), src_block(2), 'src_p:', src_p, 'tag', tag
                    reqsts(icount) = reqst
                    icount = icount + 1
                endif
            endif
            ! Edge irecv in nx- ny+
            src_block(1) = bm + 1; src_block(2) = bn - 1
            !tag = 10*(src_block(2) + (src_block(1) - 1)*bnx)
            tag = 10*(src_block(2) + (src_block(1) - 1)*bnx) + 7
            call check_block_status(src_block, src_p)
            if (src_p >= 0) then
                if (src_p /= rank) then
                    call mpi_irecv(sync_edge_buf8_recv_nxm_nyp(k), 1, mpi_real8, src_p, tag, cart_comm, reqst, ierr)
                    if (parallel_dbg >= 5) print *, rank, 'IRECV EDGE. block: ', bindx(k, 1), bindx(k, 2), 'src_block:', src_block(1), src_block(2), 'src_p:', src_p, 'tag', tag
                    reqsts(icount) = reqst
                    icount = icount + 1
                endif
            endif
            ! Edge irecv in nx- ny-
            src_block(1) = bm + 1; src_block(2) = bn + 1
            !tag = 10*(src_block(2) + (src_block(1) - 1)*bnx)
            tag = 10*(src_block(2) + (src_block(1) - 1)*bnx) + 8
            call check_block_status(src_block, src_p)
            if (src_p >= 0) then
                if (src_p /= rank) then
                    call mpi_irecv(sync_edge_buf8_recv_nxm_nym(k), 1, mpi_real8, src_p, tag, cart_comm, reqst, ierr)
                    if (parallel_dbg >= 5) print *, rank, 'IRECV EDGE. block: ', bindx(k, 1), bindx(k, 2), 'src_block:', src_block(1), src_block(2), 'src_p:', src_p, 'tag', tag
                    reqsts(icount) = reqst
                    icount = icount + 1
                endif
            endif

        enddo
        if (parallel_dbg >= 4) print *, rank, 'icount recv:', icount-1

        ! Non-blocking Send calls
        do k = 1, bcount
            bm = bindx(k, 1)
            bn = bindx(k, 2)

            !tag = bn + (bm - 1)*bnx

            ! isend in ny+
            dist_block(1) = bm; dist_block(2) = bn + 1
            tag = 10*(bn + (bm - 1)*bnx) + 1
            call check_block_status(dist_block, dist_p)
            if (dist_p >= 0) then
                if (dist_p /= rank) then
                    send_size = bnx_end(k) - bnx_start(k) + 1
                    sync_buf8_send_nyp(k)%vals = blks(k)%vals(bnx_start(k):bnx_end(k), bny_end(k))
                    call isend_real8(k, dist_block, dist_p, sync_buf8_send_nyp(k)%vals, send_size, tag, reqst)
                    !call isend_real8(k, dist_block, dist_p, blks(k)%vals(bnx_start(k):bnx_end(k), bny_end(k)), send_size, dist_block(2), reqst)
                    reqsts(icount) = reqst
                    icount = icount + 1
                else
                    lock = get_local_block_number(dist_block(1), dist_block(2))
                    blks(lock)%vals(bnx_start(lock):bnx_end(lock), bbnd_y1(lock) + 1) = blks(k)%vals(bnx_start(k):bnx_end(k), bny_end(k))
                endif
            endif
            ! isend in nx+
            dist_block(1) = bm + 1; dist_block(2) = bn
            tag = 10*(bn + (bm - 1)*bnx) + 2
            call check_block_status(dist_block, dist_p)
            if (dist_p >= 0) then
                if (dist_p /= rank) then
                    send_size = bny_end(k) - bny_start(k) + 1
                    sync_buf8_send_nxp(k)%vals = blks(k)%vals(bnx_end(k), bny_start(k):bny_end(k))
                    call isend_real8(k, dist_block, dist_p, sync_buf8_send_nxp(k)%vals, send_size, tag, reqst)
                    !call isend_real8(k, dist_block, dist_p, blks(k)%vals(bnx_end(k), bny_start(k):bny_end(k)), send_size, dist_block(2), reqst)
                    reqsts(icount) = reqst
                    icount = icount + 1
                else
                    lock = get_local_block_number(dist_block(1), dist_block(2))
                    blks(lock)%vals(bbnd_x1(lock) + 1, bny_start(lock):bny_end(lock)) = blks(k)%vals(bnx_end(k), bny_start(k):bny_end(k))
                endif
            endif
            ! isend in ny-
            dist_block(1) = bm; dist_block(2) = bn - 1
            tag = 10*(bn + (bm - 1)*bnx) + 3
            call check_block_status(dist_block, dist_p)
            if (dist_p >= 0) then
                if (dist_p /= rank) then
                    send_size = bnx_end(k) - bnx_start(k) + 1
                    sync_buf8_send_nym(k)%vals = blks(k)%vals(bnx_start(k):bnx_end(k), bny_start(k))
                    call isend_real8(k, dist_block, dist_p, sync_buf8_send_nym(k)%vals, send_size, tag, reqst)
                    !call isend_real8(k, dist_block, dist_p, blks(k)%vals(bnx_start(k):bnx_end(k), bny_start(k)), send_size, dist_block(2), reqst)
                    reqsts(icount) = reqst
                    icount = icount + 1
                else
                    lock = get_local_block_number(dist_block(1), dist_block(2))
                    blks(lock)%vals(bnx_start(lock):bnx_end(lock), bbnd_y2(lock) - 1) = blks(k)%vals(bnx_start(k):bnx_end(k), bny_start(k))
                endif
            endif
            ! isend in nx-
            dist_block(1) = bm - 1; dist_block(2) = bn
            tag = 10*(bn + (bm - 1)*bnx) + 4
            call check_block_status(dist_block, dist_p)
            if (dist_p >= 0) then
                if (dist_p /= rank) then
                    send_size = bny_end(k) - bny_start(k) + 1
                    sync_buf8_send_nxm(k)%vals = blks(k)%vals(bnx_start(k), bny_start(k):bny_end(k))
                    call isend_real8(k, dist_block, dist_p, sync_buf8_send_nxm(k)%vals, send_size, tag, reqst)
                    !call isend_real8(k, dist_block, dist_p, blks(k)%vals(bnx_start(k), bny_start(k):bny_end(k)), send_size, dist_block(2), reqst)
                    reqsts(icount) = reqst
                    icount = icount + 1
                else
                    lock = get_local_block_number(dist_block(1), dist_block(2))
                    blks(lock)%vals(bbnd_x2(lock) - 1, bny_start(lock):bny_end(lock)) = blks(k)%vals(bnx_start(k), bny_start(k):bny_end(k))
                endif
            endif

            !----------------------------Edge points----------------------------!
            !tag = 10*(bn + (bm - 1)*bnx)

            ! Edge isend in nx+ ny+
            dist_block(1) = bm + 1; dist_block(2) = bn + 1
            tag = 10*(bn + (bm - 1)*bnx) + 5
            call check_block_status(dist_block, dist_p)
            if (dist_p >= 0) then
                if (dist_p /= rank) then
                    call mpi_isend(blks(k)%vals(bnx_end(k), bny_end(k)), 1, mpi_real8, dist_p, tag, cart_comm, reqst, ierr)
                    if (parallel_dbg >= 5) print *, rank, 'ISEND EDGE. block: ', bindx(k, 1), bindx(k, 2), 'dst_block:', dist_block(1), dist_block(2), 'dst_p:', dist_p, 'tag', tag
                    reqsts(icount) = reqst
                    icount = icount + 1
                else
                    lock = get_local_block_number(dist_block(1), dist_block(2))
                    blks(lock)%vals(bbnd_x1(lock) + 1, bbnd_y1(lock) + 1) = blks(k)%vals(bnx_end(k), bny_end(k))
                endif
            endif
            ! Edge isend in nx+ ny-
            dist_block(1) = bm + 1; dist_block(2) = bn - 1
            tag = 10*(bn + (bm - 1)*bnx) + 6
            call check_block_status(dist_block, dist_p)
            if (dist_p >= 0) then
                if (dist_p /= rank) then
                    call mpi_isend(blks(k)%vals(bnx_end(k), bny_start(k)), 1, mpi_real8, dist_p, tag, cart_comm, reqst, ierr)
                    if (parallel_dbg >= 5) print *, rank, 'ISEND EDGE. block: ', bindx(k, 1), bindx(k, 2), 'dst_block:', dist_block(1), dist_block(2), 'dst_p:', dist_p, 'tag', tag
                    reqsts(icount) = reqst
                    icount = icount + 1
                else
                    lock = get_local_block_number(dist_block(1), dist_block(2))
                    blks(lock)%vals(bbnd_x1(lock) + 1, bbnd_y2(lock) - 1) = blks(k)%vals(bnx_end(k), bny_start(k))
                endif
            endif
            ! Edge isend in nx- ny+
            dist_block(1) = bm - 1; dist_block(2) = bn + 1
            tag = 10*(bn + (bm - 1)*bnx) + 7
            call check_block_status(dist_block, dist_p)
            if (dist_p >= 0) then
                if (dist_p /= rank) then
                    call mpi_isend(blks(k)%vals(bnx_start(k), bny_end(k)), 1, mpi_real8, dist_p, tag, cart_comm, reqst, ierr)
                    if (parallel_dbg >= 5) print *, rank, 'ISEND EDGE. block: ', bindx(k, 1), bindx(k, 2), 'dst_block:', dist_block(1), dist_block(2), 'dst_p:', dist_p, 'tag', tag
                    reqsts(icount) = reqst
                    icount = icount + 1
                else
                    lock = get_local_block_number(dist_block(1), dist_block(2))
                    blks(lock)%vals(bbnd_x2(lock) - 1, bbnd_y1(lock) + 1) = blks(k)%vals(bnx_start(k), bny_end(k))
                endif
            endif
            ! Edge isend in nx- ny-
            dist_block(1) = bm - 1; dist_block(2) = bn - 1
            tag = 10*(bn + (bm - 1)*bnx) + 8
            call check_block_status(dist_block, dist_p)
            if (dist_p >= 0) then
                if (dist_p /= rank) then
                    call mpi_isend(blks(k)%vals(bnx_start(k), bny_start(k)), 1, mpi_real8, dist_p, tag, cart_comm, reqst, ierr)
                    if (parallel_dbg >= 5) print *, rank, 'ISEND EDGE. block: ', bindx(k, 1), bindx(k, 2), 'dst_block:', dist_block(1), dist_block(2), 'dst_p:', dist_p, 'tag', tag
                    reqsts(icount) = reqst
                    icount = icount + 1
                else
                    lock = get_local_block_number(dist_block(1), dist_block(2))
                    blks(lock)%vals(bbnd_x2(lock) - 1, bbnd_y2(lock) - 1) = blks(k)%vals(bnx_start(k), bny_start(k))
                endif
            endif

        enddo
        if (parallel_dbg >= 4) print *, rank, 'icount totl:', icount-1

        ! Wait all, sync point
        call mpi_waitall(icount-1, reqsts, statuses, ierr)

        do k = 1, bcount
            bm = bindx(k, 1)
            bn = bindx(k, 2)

            ! ny+
            src_block(1) = bm; src_block(2) = bn - 1
            call check_block_status(src_block, src_p)
            if (src_p >= 0) then
                if (src_p /= rank) then
                    blks(k)%vals(bnx_start(k):bnx_end(k), bbnd_y1(k) + 1) = sync_buf8_recv_nyp(k)%vals
                endif
            endif
            ! nx+
            src_block(1) = bm - 1; src_block(2) = bn
            call check_block_status(src_block, src_p)
            if (src_p >= 0) then
                if (src_p /= rank) then
                    blks(k)%vals(bbnd_x1(k) + 1, bny_start(k):bny_end(k)) = sync_buf8_recv_nxp(k)%vals
                endif
            endif
            ! ny-
            src_block(1) = bm; src_block(2) = bn + 1
            call check_block_status(src_block, src_p)
            if (src_p >= 0) then
                if (src_p /= rank) then
                    blks(k)%vals(bnx_start(k):bnx_end(k), bbnd_y2(k) - 1) = sync_buf8_recv_nym(k)%vals
                endif
            endif
            ! nx-
            src_block(1) = bm + 1; src_block(2) = bn
            call check_block_status(src_block, src_p)
            if (src_p >= 0) then
                if (src_p /= rank) then
                    blks(k)%vals(bbnd_x2(k) - 1, bny_start(k):bny_end(k)) = sync_buf8_recv_nxm(k)%vals
                endif
            endif

            !----------------------------Edge points----------------------------!
            ! Edge in nx+ ny+
            src_block(1) = bm - 1; src_block(2) = bn - 1
            call check_block_status(src_block, src_p)
            if (src_p >= 0) then
                if (src_p /= rank) then
                    blks(k)%vals(bbnd_x1(k) + 1, bbnd_y1(k) + 1) = sync_edge_buf8_recv_nxp_nyp(k)
                endif
            endif
            ! Edge in nx+ ny-
            src_block(1) = bm - 1; src_block(2) = bn + 1
            call check_block_status(src_block, src_p)
            if (src_p >= 0) then
                if (src_p /= rank) then
                    blks(k)%vals(bbnd_x1(k) + 1, bbnd_y2(k) - 1) = sync_edge_buf8_recv_nxp_nym(k)
                endif
            endif
            ! Edge irecv in nx- ny+
            src_block(1) = bm + 1; src_block(2) = bn - 1
            call check_block_status(src_block, src_p)
            if (src_p >= 0) then
                if (src_p /= rank) then
                    blks(k)%vals(bbnd_x2(k) - 1, bbnd_y1(k) + 1) = sync_edge_buf8_recv_nxm_nyp(k)
                endif
            endif
            ! Edge irecv in nx- ny-
            src_block(1) = bm + 1; src_block(2) = bn + 1
            call check_block_status(src_block, src_p)
            if (src_p >= 0) then
                if (src_p /= rank) then
                    blks(k)%vals(bbnd_x2(k) - 1, bbnd_y2(k) - 1) = sync_edge_buf8_recv_nxm_nym(k)
                endif
            endif
        enddo

    end subroutine

    integer function check_cart_coord(coord, grid_size)
        implicit none
        integer, dimension(2), intent(in) :: coord, grid_size

        check_cart_coord = 0
        !write(*,*) coord,all(coord.ge.0),all((p_size-coord).ge.1)
        !print *, coord, p_size - coord, all((p_size-coord).ge.1)
        if (all(coord .ge. 0) .and. all((grid_size - coord) .ge. 1)) then
            check_cart_coord = 1
        endif
        return
    end function

    subroutine get_block_and_rank_by_point(m, n, out)
        implicit none

        integer :: m, n
        integer :: out(2)
        integer :: k, flag_r, r, flag_b, b, ierr

        flag_r = -1
        flag_b = -1
        do k = 1, bcount
            if (m >= bnx_start(k) .and. m <= bnx_end(k)) then
                if (n >= bny_start(k) .and. n <= bny_end(k)) then
                    flag_r = rank
                    flag_b = k
                endif
            endif
        enddo

        call mpi_allreduce(flag_r, r, 1, mpi_integer,      &
                           mpi_max, cart_comm, ierr)

        call mpi_allreduce(flag_b, b, 1, mpi_integer,      &
                           mpi_max, cart_comm, ierr)

        out(1) = r
        out(2) = b

    end subroutine

    integer function get_rank_by_point(m, n)
        implicit none

        integer :: m, n
        integer :: flag_r, r, ierr

        flag_r = -1
        if (m >= nx_start .and. m <= nx_end) then
            if (n >= ny_start .and. n <= ny_end) then
                flag_r = rank
            endif
        endif

        call mpi_allreduce(flag_r, r, 1, mpi_integer,      &
                           mpi_max, cart_comm, ierr)

        get_rank_by_point = r
        return
    end function

endmodule mpi_parallel_tools
