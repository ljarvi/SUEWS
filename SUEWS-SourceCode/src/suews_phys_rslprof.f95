MODULE rsl_module
   USE AtmMoistStab_module, ONLY: neut_limit, cal_Stab, stab_psi_mom, stab_psi_heat, stab_phi_mom, stab_phi_heat
   USE meteo, ONLY: RH2qa, qa2RH
   USE resist_module, ONLY: SUEWS_cal_RoughnessParameters
   USE allocateArray, ONLY: &
      nsurf, BldgSurf, ConifSurf, DecidSurf, ncolumnsDataOutRSL
   IMPLICIT NONE

   INTEGER, PARAMETER :: nz = 30   ! number of levels 10 levels in canopy plus 20 (3 x Zh) above the canopy

CONTAINS

   SUBROUTINE RSLProfile( &
      Zh, z0m, zdm, z0v, &
      L_MOD, sfr, FAI, StabilityMethod, RA_h, &
      avcp, lv_J_kg, avdens, &
      avU1, Temp_C, avRH, Press_hPa, zMeas, qh, qe, &  ! input
      T2_C, q2_gkg, U10_ms, RH2, &!output
      dataoutLineRSL) ! output
      !-----------------------------------------------------
      ! calculates windprofiles using MOST with a RSL-correction
      ! based on Harman & Finnigan 2007
      !
      ! last modified by:
      ! NT 16 Mar 2019: initial version
      ! TS 16 Oct 2019: improved consistency in parameters/varaibles within SUEWS
      ! TODO how to improve the speed of this code
      !
      !-----------------------------------------------------

      IMPLICIT NONE

      REAL(KIND(1D0)), DIMENSION(nsurf), INTENT(in) ::sfr! surface fractions [-]
      REAL(KIND(1D0)), INTENT(in):: zMeas  ! height of atmospheric forcing [m]
      REAL(KIND(1D0)), INTENT(in):: avU1   ! Wind speed at forcing height [m s-1]
      REAL(KIND(1D0)), INTENT(in):: Temp_C ! Air temperature at forcing height [C]
      REAL(KIND(1D0)), INTENT(in):: avRH   ! relative humidity at forcing height [-]
      REAL(KIND(1D0)), INTENT(in):: Press_hPa ! pressure at forcing height [hPa]
      REAL(KIND(1D0)), INTENT(in):: L_MOD  ! Obukhov length [m]
      REAL(KIND(1D0)), INTENT(in):: RA_h  ! aerodynamic resistance for heat [s m-1]
      REAL(KIND(1D0)), INTENT(in):: avcp  ! specific heat capacity [J kg-1 K-1]
      REAL(KIND(1D0)), INTENT(in):: lv_J_kg  ! Latent heat of vaporization in [J kg-1]
      REAL(KIND(1D0)), INTENT(in):: avdens  ! air density [kg m-3]
      REAL(KIND(1D0)), INTENT(in):: qh  ! sensible heat flux [W m-2]
      REAL(KIND(1D0)), INTENT(in):: qe     ! Latent heat flux [W m-2]
      REAL(KIND(1D0)), INTENT(in):: Zh     ! Mean building height [m]
      REAL(KIND(1D0)), INTENT(in):: z0m     ! roughness for momentum [m]
      REAL(KIND(1D0)), INTENT(in):: z0v  ! roughnesslength for heat [s m-1]
      REAL(KIND(1D0)), INTENT(in):: zdm     ! zero-plane displacement [m]
      REAL(KIND(1D0)), INTENT(in):: FAI  ! Frontal area index [-]

      INTEGER, INTENT(in)::StabilityMethod

      REAL(KIND(1D0)), INTENT(out):: T2_C ! Air temperature at 2 m [C]
      REAL(KIND(1D0)), INTENT(out):: q2_gkg ! Air specific humidity at 2 m [g kg-1]
      REAL(KIND(1D0)), INTENT(out):: U10_ms ! wind speed at 10 m [m s-1]
      REAL(KIND(1D0)), INTENT(out):: RH2 ! Air relative humidity [-]

      INTEGER, PARAMETER :: nz = 30   ! number of levels 10 levels in canopy plus 20 (3 x Zh) above the canopy

      REAL(KIND(1D0)), PARAMETER:: cd_tree = 1.2, & ! drag coefficient tree canopy !!!!needs adjusting!!!
                                   a_tree = 0.05, & ! the foliage area per unit volume !!!!needs adjusting!!!
                                   kappa = 0.40, &! von karman constant
                                   !   lv_J_kg = 2.5E6, &! latent heat for water vapor!!! make consistant with rest of code
                                   beta_N = 0.40, &  ! H&F beta coefficient in neutral conditions from Theeuwes et al., 2019 BLM
                                   pi = 4.*ATAN(1.0), r = 0.1, &
                                   a1 = 4., a2 = -0.1, a3 = 1.5, a4 = -1. ! constraints to determine beta

      ! Variables array [z,U,T,q, 12 debug vars]
      ! z: height array
      ! U,T,q: wind speed, air temp, specific humidity at z;
      ! debug vars: see dataoutLineRSL
      REAL(KIND(1D0)), INTENT(out), DIMENSION(ncolumnsDataOutRSL - 5):: dataoutLineRSL
      REAL(KIND(1D0)), DIMENSION(nz):: psihatm_z
      REAL(KIND(1D0)), DIMENSION(nz):: psihath_z
      REAL(KIND(1D0)), DIMENSION(nz):: dif
      ! REAL(KIND(1d0)), DIMENSION(nz):: psihatm_z, psihath_z
      REAL(KIND(1D0)), DIMENSION(nz):: zarray
      REAL(KIND(1D0)), DIMENSION(nz):: dataoutLineURSL ! wind speed array [m s-1]
      REAL(KIND(1D0)), DIMENSION(nz):: dataoutLineTRSL ! Temperature array [C]
      REAL(KIND(1D0)), DIMENSION(nz):: dataoutLineqRSL ! Specific humidity array [g kg-1]

      REAL(KIND(1D0))::z0_RSL  ! roughness length from H&F
      REAL(KIND(1D0))::zd_RSL ! zero-plane displacement

      ! REAL(KIND(1d0))::Lc_build, Lc_tree, Lc ! canopy drag length scale
      REAL(KIND(1D0))::Lc ! canopy drag length scale
      ! REAL(KIND(1d0))::Lc_stab ! threshold of canopy drag length scale under stable conditions
      ! REAL(KIND(1d0))::Lc_unstab ! threshold of canopy drag length scale under unstable conditions
      REAL(KIND(1D0))::Scc ! Schmidt number for temperature and humidity
      REAL(KIND(1D0))::psimz, psimz0, psimza, phimzp, phimz, phihzp, phihz, psihz, psihz0, psihza  ! stability function for momentum
      ! REAL(KIND(1d0))::betaHF, betaNL, beta, betaN2  ! beta coefficient from Harman 2012
      REAL(KIND(1D0))::beta  ! beta coefficient from Harman 2012
      REAL(KIND(1D0))::elm ! mixing length
      ! REAL(KIND(1d0))::xxm1, xxm1_2, xxh1, xxh1_2, dphi, dphih ! dummy variables for stability functions
      REAL(KIND(1D0))::f, cm, c2, ch, c2h ! H&F'07 and H&F'08 'constants'
      REAL(KIND(1D0))::t_h, q_h ! H&F'08 canopy corrections
      REAL(KIND(1D0))::TStar_RSL ! temperature scale
      REAL(KIND(1D0))::UStar_RSL ! friction velocity used in RSL
      REAL(KIND(1D0))::UStar_heat ! friction velocity derived from RA_h with correction/restriction
      REAL(KIND(1D0))::PAI ! plan area index, including areas of roughness elements: buildings and trees
      ! REAL(KIND(1d0))::sfr_tr ! land cover fraction of trees
      REAL(KIND(1D0))::L_MOD_RSL ! Obukhov length used in RSL module with thresholds applied
      ! real(KIND(1D0))::L_stab ! threshold for Obukhov length under stable conditions
      ! real(KIND(1D0))::L_unstab ! threshold for Obukhov length under unstable conditions

      REAL(KIND(1D0))::zH_RSL ! mean canyon height used in RSL module with thresholds applied
      REAL(KIND(1D0))::dz! initial height step
      REAL(KIND(1D0))::phi_hatmZh, phim_zh
      ! REAL(KIND(1d0)), parameter::zH_min = 8! limit for minimum canyon height used in RSL module
      REAL(KIND(1D0)), PARAMETER::ratio_dz = 1.618! ratio between neighbouring height steps

      REAL(KIND(1D0))::qa_gkg, qStar_RSL ! specific humidity scale
      INTEGER :: I, z, idx_can, idx_za, idx_2m, idx_10m
      INTEGER :: nz_can ! number of heights in canyon

      LOGICAL:: flag_RSL ! whether RSL correction is used

      ! CHARACTER(len=1024) :: Errmessage
      !
      ! Step 1: Calculate grid-cell dependent constants
      ! Step 2: Calculate Beta (crucial for H&F method)
      ! Step 3: calculate the stability dependent H&F constants
      ! Step 4: determine psihat at levels above the canopy
      ! Step 5: Calculate z0 iteratively
      ! Step 6: Calculate mean variables above canopy
      ! Step 7: Calculate mean variables in canopy
      !
      ! ! Step 1
      ! ! Start setting up the parameters

      CALL RSL_cal_prms( &
         StabilityMethod, &!input
         zh, L_MOD, sfr, FAI, &!input
         zH_RSL, L_MOD_RSL, &
         Lc, beta, zd_RSL, z0_RSL, elm, Scc, f, PAI)

      ! Define the height array with consideration of key heights
      ! set number of heights within canopy
      IF (Zh_RSL <= 2) THEN
         nz_can = 3
      ELSE IF (Zh_RSL <= 10) THEN
         nz_can = 10
      ELSE
         nz_can = 15
      END IF
      ! fill up heights in canopy
      dz = Zh_RSL/nz_can
      DO i = 1, nz_can
         zarray(i) = dz*i
      END DO

      ! guaranttee 2 m is within the zarray
      IF (dz > 2) zarray(1) = 1.999

      zarray(nz_can) = Zh_RSL
      ! fill up heights above canopy
      dz = (zMeas - Zh_RSL)/(nz - nz_can)
      DO i = nz_can + 1, nz
         zarray(i) = Zh_RSL + (i - nz_can)*dz
      END DO

      ! add key heights (2m and 10m) to zarray
      ! 2m:
      ! DO z = 1, nz
      !    dif(z) = ABS(zarray(z) - 2)
      ! ENDDO
      ! idx_2m = MINLOC(dif, DIM=1)
      ! zarray(idx_2m) = 2
      idx_2m = 2
      ! 10m:
      ! DO z = 1, nz
      !    dif(z) = ABS(zarray(z) - 10)
      ! ENDDO
      ! idx_10m = MINLOC(dif, DIM=1)
      ! zarray(idx_10m) = 10
      idx_10m = 4

      ! determine index at the canyon top
      DO z = 1, nz
         dif(z) = ABS(zarray(z) - Zh_RSL)
      END DO
      idx_can = MINLOC(dif, DIM=1)
      zarray(idx_can) = Zh_RSL

      ! determine index at measurement height
      ! DO z = 1, nz
      !    dif(z) = ABS(zarray(z) - zMeas)
      ! ENDDO
      idx_za = nz
      zarray(idx_za) = zMeas

      ! see Fig 1 of Grimmond and Oke (1999) for the range for 'real cities'
      ! PAI ~ [0.1,.61], FAI ~ [0.05,0.45], zH_RSL > 2 m
      flag_RSL = (1.-PAI)/FAI <= 18 .AND. (1.-PAI)/FAI > .021 &
                 .AND. zH_RSL >= 5
      ! &
      ! .and. PAI>0.1 .and. PAI<0.61
      IF (flag_RSL) THEN
         ! use RSL approach to calculate correction factors
         ! Step 3: calculate the stability dependent H&F constants

         CALL cal_ch(StabilityMethod, zh_RSL, zd_RSL, Lc, beta, L_MOD_RSL, Scc, f, c2h, ch)
         CALL cal_cm(StabilityMethod, zH_RSL, zd_RSL, Lc, beta, L_MOD_RSL, c2, cm, phi_hatmZh, phim_zh)

         ! Step 4: determine psihat at levels above the canopy
         psihatm_z = 0.*zarray
         psihath_z = 0.*zarray
         DO z = nz - 1, idx_can, -1
            phimz = stab_phi_mom(StabilityMethod, (zarray(z) - zd_RSL)/L_MOD_RSL)
            phimzp = stab_phi_mom(StabilityMethod, (zarray(z + 1) - zd_RSL)/L_MOD_RSL)
            phihz = stab_phi_heat(StabilityMethod, (zarray(z) - zd_RSL)/L_MOD_RSL)
            phihzp = stab_phi_heat(StabilityMethod, (zarray(z + 1) - zd_RSL)/L_MOD_RSL)

            psihatm_z(z) = psihatm_z(z + 1) + dz/2.*phimzp*(cm*EXP(-1.*c2*beta*(zarray(z + 1) - zd_RSL)/elm)) &  !Taylor's approximation for integral
                           /(zarray(z + 1) - zd_RSL)
            psihatm_z(z) = psihatm_z(z) + dz/2.*phimz*(cm*EXP(-1.*c2*beta*(zarray(z) - zd_RSL)/elm)) &
                           /(zarray(z) - zd_RSL)
            psihath_z(z) = psihath_z(z + 1) + dz/2.*phihzp*(ch*EXP(-1.*c2h*beta*(zarray(z + 1) - zd_RSL)/elm)) &  !Taylor's approximation for integral
                           /(zarray(z + 1) - zd_RSL)
            psihath_z(z) = psihath_z(z) + dz/2.*phihz*(ch*EXP(-1.*c2h*beta*(zarray(z) - zd_RSL)/elm)) &
                           /(zarray(z) - zd_RSL)
         END DO

      ELSE

         ! correct parameters if RSL approach doesn't apply for scenario of isolated flows
         ! see Fig 1 of Grimmond and Oke (1999)
         ! when isolated flow or skimming flow, implying RSL doesn't apply, force RSL correction to zero
         psihatm_z = 0
         psihath_z = 0

         ! use L_MOD as in other parts of SUEWS
         L_MOD_RSL = L_MOD

         !correct RSL-based using SUEWS system-wide values
         z0_RSL = z0m
         zd_RSL = zdm
         ! if (zh_rsl <= zd_RSL) then
         !    ! this may happen as only building height is considered in calculation of zd
         !    zd_RSL = 0.99*zh_rsl
         ! end if

         ! correct elm uisng suggested valid thresholds by Harman and Finnigan (2007)
         IF (L_MOD_RSL > 0) THEN
            ! eqn 25 in HF07 assuming gamma==1, stable condition:
            Lc = MIN(2.2*kappa/beta*L_MOD_RSL, Lc)
         ELSE
            ! eqn 26 in HF07, unstable condition:
            Lc = MAX(-2/beta**2*L_MOD_RSL, Lc)
         END IF
         elm = cal_elm_RSL(beta, Lc)

         ! then MOST recovers from RSL correction
      END IF

      ! Step 6: Calculate mean variables above canopy
      !
      psimz0 = stab_psi_mom(StabilityMethod, z0_RSL/L_MOD_RSL)
      psimza = stab_psi_mom(StabilityMethod, (zMeas - zd_RSL)/L_MOD_RSL)
      psihza = stab_psi_heat(StabilityMethod, (zMeas - zd_RSL)/L_MOD_RSL)

      UStar_RSL = avU1*kappa/(LOG((zMeas - zd_RSL)/z0_RSL) - psimza + psimz0 + psihatm_z(nz))

      ! TS 11 Feb 2021: limit UStar and TStar to reasonable ranges
      ! under all conditions, min(UStar)==0.001 m s-1 (Jimenez et al 2012, MWR, https://doi.org/10.1175/mwr-d-11-00056.1
      UStar_RSL = MAX(0.001, UStar_RSL)
      ! under convective/unstable condition, min(UStar)==0.15 m s-1: (Schumann 1988, BLM, https://doi.org/10.1007/BF00123019)
      IF ((ZMeas - zd_RSL)/L_MOD_RSL < -neut_limit) UStar_RSL = MAX(0.15, UStar_RSL)

      ! TStar_RSL = -1.*(qh/(avcp*avdens))/UStar_RSL
      ! qStar_RSL = -1.*(qe/lv_J_kg*avdens)/UStar_RSL
      IF (flag_RSL) THEN
         UStar_heat = MAX(0.15, UStar_RSL)
      ELSE
         ! use UStar_heat implied by RA_h using MOST
         psihz0 = stab_psi_heat(StabilityMethod, z0v/L_MOD_RSL)
         UStar_heat = 1/(kappa*RA_h)*(LOG((zMeas - zd_RSL)/z0v) - psihza + psihz0)
      END IF
      TStar_RSL = -1.*(qh/(avcp*avdens))/UStar_heat
      IF (qe == 0.0) THEN
         qStar_RSL = 10.**(-10) ! avoid the situation where qe=0, qstar_RSL=0 and the code breaks LB 21 May 2021
      ELSE
         qStar_RSL = -1.*(qe/lv_J_kg*avdens)/UStar_heat
      ENDIF
      qa_gkg = RH2qa(avRH/100, Press_hPa, Temp_c)
      DO z = idx_can, nz
         psimz = stab_psi_mom(StabilityMethod, (zarray(z) - zd_RSL)/L_MOD_RSL)
         psihz = stab_psi_heat(StabilityMethod, (zarray(z) - zd_RSL)/L_MOD_RSL)
         dataoutLineURSL(z) = (LOG((zarray(z) - zd_RSL)/z0_RSL) - psimz + psimz0 + psihatm_z(z))/kappa ! eqn. 3 in Theeuwes et al. (2019 BLM)
         dataoutLineTRSL(z) = (LOG((zarray(z) - zd_RSL)/(zMeas - zd_RSL)) - psihz + psihza + psihath_z(z) - psihath_z(idx_za))/kappa ! eqn. 4 in Theeuwes et al. (2019 BLM)
         dataoutLineqRSL(z) = dataoutLineTRSL(z)
      END DO
      !
      ! Step 7: calculate in canopy variables
      !
      IF (flag_RSL) THEN
         ! RSL approach: exponential profiles within canopy
         IF (idx_can > 1) THEN
            t_h = Scc*TStar_RSL/(beta*f)
            q_h = Scc*qStar_RSL/(beta*f)
            DO z = 1, idx_can - 1
               dataoutLineURSL(z) = dataoutLineURSL(idx_can)*EXP(beta*(zarray(z) - Zh_RSL)/elm)
               dataoutLineTRSL(z) = dataoutLineTRSL(idx_can) + (t_h*EXP(beta*f*(zarray(z) - Zh_RSL)/elm) - t_h)/TStar_RSL
               dataoutLineqRSL(z) = dataoutLineqRSL(idx_can) + (q_h*EXP(beta*f*(zarray(z) - Zh_RSL)/elm) - q_h)/qStar_RSL
            END DO
         END IF
      ELSE
         ! MOST approach:
         DO z = 1, idx_can
            if ( zarray(z) <= zd_RSL ) zarray(z)=1.01*zd_RSL
            psimz = stab_psi_mom(StabilityMethod, (zarray(z) - zd_RSL)/L_MOD_RSL)
            psihz = stab_psi_heat(StabilityMethod, (zarray(z) - zd_RSL)/L_MOD_RSL)
            dataoutLineURSL(z) = (LOG((zarray(z) - zd_RSL)/z0_RSL) - psimz + psimz0)/kappa
            dataoutLineTRSL(z) = (LOG((zarray(z) - zd_RSL)/(zMeas - zd_RSL)) - psihz + psihza)/kappa
            dataoutLineqRSL(z) = dataoutLineTRSL(z)
         END DO
      END IF
      dataoutLineURSL = dataoutLineURSL*UStar_RSL
      dataoutLineTRSL = dataoutLineTRSL*TStar_RSL + Temp_C
      dataoutLineqRSL = (dataoutLineqRSL*qStar_RSL + qa_gkg/1000.)*1000.

      dataoutLineRSL = [zarray, dataoutLineURSL, dataoutLineTRSL, dataoutLineqRSL, &
                        !information for debugging
                        ! L_stab, L_unstab,
                        L_MOD_RSL, &
                        zH_RSL, &
                        ! Lc_stab, Lc_unstab,
                        Lc, &
                        beta, zd_RSL, z0_RSL, elm, Scc, f, UStar_RSL, UStar_heat, TStar_RSL, FAI, PAI, MERGE(1.D0, 0.D0, flag_RSL) &
                        ]

      !
      ! Step 8
      ! retrieve the diagnostics at key heights
      !
      T2_C = interp_z(2D0, zarray, dataoutLineTRSL)
      q2_gkg = interp_z(2D0, zarray, dataoutLineqRSL)
      U10_ms = interp_z(10D0, zarray, dataoutLineURSL)
      ! get relative humidity:
      RH2 = qa2RH(q2_gkg, press_hPa, T2_C)

   END SUBROUTINE RSLProfile

   FUNCTION interp_z(z_x, z, v) RESULT(v_x)

      REAL(KIND(1D0)), INTENT(in) ::  z_x ! height to interpolate at
      REAL(KIND(1D0)), DIMENSION(nz), INTENT(in) ::  z ! heights
      REAL(KIND(1D0)), DIMENSION(nz), INTENT(in) ::  v ! values associated with heights

      ! output
      REAL(KIND(1D0)) ::v_x ! zd used in RSL

      ! local variables
      REAL(KIND(1D0)) ::slope! slope
      REAL(KIND(1D0)) ::dz! slope
      REAL(KIND(1D0)), DIMENSION(nz) ::dif! slope
      INTEGER :: idx_low! vertical index lower than z_x
      INTEGER :: idx_x! vertical index lower than z_x
      INTEGER :: idx_high! vertical index higher than z_x
      INTEGER :: idx! vertical index higher than z_x
      INTEGER, PARAMETER::nz = 30! vertical index higher than z_x

      ! initialise variables
      idx_x = 0

      dif = z - z_x
      idx_x = MAXLOC(dif, 1, ABS(dif) < 1.D-6)
      idx_low = MAXLOC(dif, 1, dif < 0.)
      idx_high = MINLOC(dif, 1, dif > 0.)

      IF (idx_x > 0) THEN
         ! z_x is one of zarray elements
         v_x = v(idx_x)
      ELSE
         ! linear interpolation is performed
         dz = z(idx_high) - z(idx_low)
         slope = (v(idx_high) - v(idx_low))/dz
         v_x = v(idx_low) + (z_x - z(idx_low))*slope
      END IF

   END FUNCTION interp_z

   FUNCTION cal_elm_RSL(beta, Lc) RESULT(elm)

      REAL(KIND(1D0)), INTENT(in) ::  Lc ! height scale for bluff bodies [m]
      REAL(KIND(1D0)), INTENT(in) ::  beta ! parameter in RSL

      ! output
      REAL(KIND(1D0)) ::elm ! zd used in RSL

      elm = 2.*beta**3*Lc

   END FUNCTION cal_elm_RSL

   RECURSIVE FUNCTION cal_psim_hat(StabilityMethod, z, zh_RSL, L_MOD, beta, Lc) RESULT(psim_hat_z)
      ! calculate psi_hat for momentum
      ! TS, 23 Oct 2019
      IMPLICIT NONE
      INTEGER, INTENT(in) :: StabilityMethod ! stability method
      REAL(KIND(1D0)), INTENT(in) :: z ! height of interest [m]
      REAL(KIND(1D0)), INTENT(in) ::  zh_RSL ! canyon depth [m]
      REAL(KIND(1D0)), INTENT(in) ::  Lc ! height scale for bluff bodies [m]
      REAL(KIND(1D0)), INTENT(in) ::  beta ! parameter in RSL
      REAL(KIND(1D0)), INTENT(in) ::  L_MOD ! Obukhov length [m]

      ! output
      REAL(KIND(1D0)) ::psim_hat_z ! psim_hat at height of interest

      ! internal variables
      REAL(KIND(1D0)) ::zp ! a height above z used for iterative calculations
      REAL(KIND(1D0)) ::zd_RSL ! displacement height used in RSL
      REAL(KIND(1D0)) ::phim_lc ! displacement height used in RSL
      REAL(KIND(1D0)) ::phim_z ! displacement height used in RSL
      REAL(KIND(1D0)) ::phim_zp ! displacement height used in RSL
      REAL(KIND(1D0)) ::phim_hat_zp ! displacement height used in RSL
      REAL(KIND(1D0)) ::phim_hat_z ! displacement height used in RSL
      REAL(KIND(1D0)) ::psim_hat_zp ! displacement height used in RSL
      REAL(KIND(1D0)) ::elm ! displacement height used in RSL
      ! real(KIND(1D0)) ::xxm1 ! displacement height used in RSL
      ! real(KIND(1D0)) ::xxm1_2 ! displacement height used in RSL
      ! real(KIND(1D0)) ::dphi ! displacement height used in RSL
      ! real(KIND(1D0)) ::phi_hatmZh ! displacement height used in RSL
      ! real(KIND(1D0)) ::cm
      ! real(KIND(1D0)) ::c2
      ! real(KIND(1D0)) ::phi_hatmZh, phim_zh

      REAL(KIND(1D0)), PARAMETER::kappa = 0.40
      REAL(KIND(1D0)), PARAMETER::dz = 0.1 !height step

      IF (z > 100) THEN
         psim_hat_z = 0.
         RETURN
      END IF

      zp = 1.01*z ! a height above z

      zd_RSL = cal_zd_RSL(Zh_RSL, beta, lc)
      elm = cal_elm_RSL(beta, lc)

      ! phim at Lc
      phim_lc = stab_phi_mom(StabilityMethod, Lc/L_MOD)

      phim_z = stab_phi_mom(StabilityMethod, (z - zd_RSL)/L_MOD)
      phim_zp = stab_phi_mom(StabilityMethod, (zp - zd_RSL)/L_MOD)

      psim_hat_zp = cal_psim_hat(StabilityMethod, zp, zh_RSL, L_MOD, beta, Lc)

      !Taylor's approximation for integral
      ! psim_hat_z = psim_hat_zp + dz/2.*phim_zp*(cm*EXP(-1.*c2*beta*(zp - zd_RSL)/elm))/(zp - zd_RSL)
      ! psim_hat_z = psim_hat_z + dz/2.*phim_z*(cm*EXP(-1.*c2*beta*(z - zd_RSL)/elm))/(z - zd_RSL)
      phim_hat_zp = cal_phim_hat(StabilityMethod, zp, zh_RSL, L_MOD, beta, lc)
      phim_hat_z = cal_phim_hat(StabilityMethod, z, zh_RSL, L_MOD, beta, lc)

      psim_hat_z = psim_hat_zp + dz/2.*phim_zp*(1 - phim_hat_zp)/(zp - zd_RSL)
      psim_hat_z = psim_hat_z + dz/2.*phim_z*(1 - phim_hat_z)/(z - zd_RSL)

   END FUNCTION cal_psim_hat

   FUNCTION cal_phim_hat(StabilityMethod, z, zh_RSL, L_MOD, beta, lc) RESULT(phim_hat)
      IMPLICIT NONE
      INTEGER, INTENT(in) :: StabilityMethod ! stability method
      REAL(KIND(1D0)), INTENT(in) :: z
      REAL(KIND(1D0)), INTENT(in) :: zh_RSL
      REAL(KIND(1D0)), INTENT(in) :: L_MOD
      REAL(KIND(1D0)), INTENT(in) :: beta
      REAL(KIND(1D0)), INTENT(in) :: lc
      REAL(KIND(1D0)) :: phim_hat
      REAL(KIND(1D0)) :: zd_RSL

      REAL(KIND(1D0)) :: elm
      REAL(KIND(1D0)) :: c2
      REAL(KIND(1D0)) :: cm, phi_hatmZh, phim_zh

      elm = cal_elm_RSL(beta, lc)

      zd_RSL = cal_zd_RSL(Zh_RSL, beta, lc)

      CALL cal_cm(StabilityMethod, zh_RSL, zd_RSL, Lc, beta, L_MOD, c2, cm, phi_hatmZh, phim_zh)

      phim_hat = 1 - cm*EXP(-1.*c2*beta*(z - zd_RSL)/elm)

   END FUNCTION cal_phim_hat

   SUBROUTINE cal_cm(StabilityMethod, zh_RSL, zd_RSL, Lc, beta, L_MOD, c2, cm, phi_hatmZh, phim_zh)

      IMPLICIT NONE
      INTEGER, INTENT(in) :: StabilityMethod ! stability method
      ! real(KIND(1D0)), intent(in) :: z ! height of interest [m]
      REAL(KIND(1D0)), INTENT(in) ::  zh_RSL ! canyon depth [m]
      REAL(KIND(1D0)), INTENT(in) ::  zd_RSL ! canyon depth [m]
      REAL(KIND(1D0)), INTENT(in) ::  Lc ! height scale for bluff bodies [m]
      REAL(KIND(1D0)), INTENT(in) ::  beta ! parameter in RSL
      REAL(KIND(1D0)), INTENT(in) ::  L_MOD ! Obukhov length [m]

      ! output
      REAL(KIND(1D0)), INTENT(out) ::c2
      REAL(KIND(1D0)), INTENT(out) ::cm
      REAL(KIND(1D0)), INTENT(out) ::phi_hatmZh
      REAL(KIND(1D0)), INTENT(out) ::phim_zh

      ! internal variables
      ! real(KIND(1D0)) ::phim_zh
      REAL(KIND(1D0)) ::phim_zhdz
      REAL(KIND(1D0)) ::dphi
      ! real(KIND(1D0)) ::phi_hatmZh

      REAL(KIND(1D0)), PARAMETER::kappa = 0.40
      REAL(KIND(1D0)), PARAMETER::dz = 0.1 !height step

      phim_zh = stab_phi_mom(StabilityMethod, (Zh_RSL - zd_RSL)/L_MOD)
      phim_zhdz = stab_phi_mom(StabilityMethod, (Zh_RSL - zd_RSL + dz)/L_MOD)

      dphi = (phim_zhdz - phim_zh)/dz
      IF (phim_zh /= 0.) THEN
         phi_hatmZh = kappa/(2.*beta*phim_zh)
      ELSE
         ! neutral condition
         phi_hatmZh = 1.
      END IF

      IF (phi_hatmZh >= 1.) THEN
         ! more stable, but less correct
         c2 = 0.5
         phi_hatmZh = 1.
      ELSE
         ! if very unstable this might cause some high values of psihat_z
         c2 = (kappa*(3.-(2.*beta**2.*Lc/phim_zh*dphi)))/(2.*beta*phim_zh - kappa)
      END IF
      ! force c2 to 0.5 for better stability. TS 14 Jul 2020
      ! TODO: a more proper threshold needs to be determined
      c2 = 0.5

      cm = (1.-phi_hatmZh)*EXP(c2/2.)

   END SUBROUTINE cal_cm

   SUBROUTINE cal_ch(StabilityMethod, zh_RSL, zd_RSL, Lc, beta, L_MOD, Scc, f, c2h, ch)

      IMPLICIT NONE
      INTEGER, INTENT(in) :: StabilityMethod ! stability method
      ! real(KIND(1D0)), intent(in) :: z ! height of interest [m]
      REAL(KIND(1D0)), INTENT(in) ::  zh_RSL ! canyon depth [m]
      REAL(KIND(1D0)), INTENT(in) ::  zd_RSL ! canyon depth [m]
      REAL(KIND(1D0)), INTENT(in) ::  Scc !
      REAL(KIND(1D0)), INTENT(in) ::  f !
      REAL(KIND(1D0)), INTENT(in) ::  Lc ! height scale for bluff bodies [m]
      REAL(KIND(1D0)), INTENT(in) ::  beta ! parameter in RSL
      REAL(KIND(1D0)), INTENT(in) ::  L_MOD ! Obukhov length [m]

      ! output
      REAL(KIND(1D0)), INTENT(out) ::ch
      REAL(KIND(1D0)), INTENT(out) ::c2h ! displacement height used in RSL

      ! internal variables
      REAL(KIND(1D0)) ::phih_zh ! displacement height used in RSL
      REAL(KIND(1D0)) ::phih_zhdz ! displacement height used in RSL
      REAL(KIND(1D0)) ::dphih ! displacement height used in RSL
      REAL(KIND(1D0)) ::phi_hathZh ! displacement height used in RSL

      REAL(KIND(1D0)), PARAMETER::kappa = 0.40
      REAL(KIND(1D0)), PARAMETER::dz = 0.1 !height step

      phih_zh = stab_phi_heat(StabilityMethod, (Zh_RSL - zd_RSL)/L_MOD)
      phih_zhdz = stab_phi_heat(StabilityMethod, (Zh_RSL - zd_RSL + 1.)/L_MOD)

      dphih = phih_zhdz - phih_zh
      IF (phih_zh /= 0.) THEN
         phi_hathZh = kappa*Scc/(2.*beta*phih_zh)
      ELSE
         phi_hathZh = 1.
      END IF

      IF (phi_hathZh >= 1.) THEN
         ! more stable, but less correct
         c2h = 0.5
         phi_hathZh = 1.
      ELSE
         ! if very unstable this might cause some high values of psihat_z
         c2h = (kappa*Scc*(2.+f - (dphih*2.*beta**2.*Lc/phih_zh)))/(2.*beta*phih_zh - kappa*Scc)
      END IF
      ! force c2h to 0.5 for better stability. TS 14 Jul 2020
      ! TODO: a more proper threshold needs to be determined
      c2h = 0.5

      ch = (1.-phi_hathZh)*EXP(c2h/2.)

   END SUBROUTINE cal_ch

   ! function cal_psihatm_z(StabilityMethod, nz, zarray, L_MOD_RSL, zH_RSL, Lc, beta, zd, elm) result(psihatm_z)

   !    ! calculate psi_hat for momentum
   !    ! TS, 23 Oct 2019
   !    implicit none
   !    integer, intent(in) :: StabilityMethod ! stability method
   !    integer, intent(in) :: nz ! number of vertical layers
   !    real(KIND(1D0)), DIMENSION(nz), intent(in) :: zarray ! height of interest [m]
   !    real(KIND(1D0)), intent(in) ::  zh_RSL ! canyon depth [m]
   !    real(KIND(1D0)), intent(in) ::  Lc ! height scale for bluff bodies [m]
   !    real(KIND(1D0)), intent(in) ::  beta ! parameter in RSL
   !    real(KIND(1D0)), intent(in) ::  L_MOD_RSL ! Obukhov length [m]
   !    real(KIND(1D0)), intent(in) ::zd ! displacement height used in RSL
   !    real(KIND(1D0)), intent(in) ::elm ! displacement height used in RSL

   !    ! output
   !    real(KIND(1D0)), DIMENSION(nz) ::psihatm_z ! psim_hat at height of interest

   !    ! internal variables
   !    ! real(KIND(1D0)) ::zp ! a height above z used for iterative calculations
   !    ! real(KIND(1D0)) ::phim_lc ! displacement height used in RSL
   !    real(KIND(1D0)) ::phimz ! displacement height used in RSL
   !    real(KIND(1D0)) ::phimzp ! displacement height used in RSL
   !    ! real(KIND(1D0)) ::psim_hat_zp ! displacement height used in RSL
   !    real(KIND(1D0)) ::xxm1 ! displacement height used in RSL
   !    real(KIND(1D0)) ::xxm1_2 ! displacement height used in RSL
   !    real(KIND(1D0)) ::dphi ! displacement height used in RSL
   !    real(KIND(1D0)) ::phi_hatmZh ! displacement height used in RSL
   !    real(KIND(1D0)) ::cm ! displacement height used in RSL
   !    real(KIND(1D0)) ::c2 ! displacement height used in RSL
   !    REAL(KIND(1d0)), DIMENSION(nz):: dif

   !    REAL(KIND(1d0)), PARAMETER::kappa = 0.40
   !    REAL(KIND(1d0)), PARAMETER::dz = 0.1 !height step

   !    integer::z, idx_can

   !    psihatm_z = 0.*zarray

   !    ! determine index at the canyon top
   !    DO z = 1, nz
   !       dif(z) = ABS(zarray(z) - Zh_RSL)
   !    ENDDO
   !    idx_can = MINLOC(dif, DIM=1)
   !    ! zarray(idx_can) = Zh_RSL

   !    ! calculate phihatM according to H&F '07 and H&F '08 for heat and humidity
   !    xxm1 = stab_phi_mom(StabilityMethod, (Zh_RSL - zd)/L_MOD_RSL)
   !    xxm1_2 = stab_phi_mom(StabilityMethod, (Zh_RSL - zd + 1.)/L_MOD_RSL)

   !    phi_hatmZh = kappa/(2.*beta*xxm1)
   !    dphi = xxm1_2 - xxm1

   !    IF (phi_hatmZh > 1.) THEN
   !       c2 = 0.5 ! more stable, but less correct
   !       ! c2h = 0.5
   !    ELSE
   !       c2 = (kappa*(3.-(2.*beta**2.*Lc/xxm1*dphi)))/(2.*beta*xxm1 - kappa)  ! if very unstable this might cause some high values of psihat_z
   !       ! c2h = (kappa*Scc*(2.+f - (dphih*2.*beta**2.*Lc/xxh1)))/(2.*beta*xxh1 - kappa*Scc)
   !    ENDIF
   !    cm = (1.-phi_hatmZh)*EXP(c2/2.)
   !    ! ch = (1.-phi_hathzh)*EXP(c2h/2.)

   !    DO z = nz - 1, idx_can - 1, -1
   !       phimz = stab_phi_mom(StabilityMethod, (zarray(z) - zd)/L_MOD_RSL)
   !       phimzp = stab_phi_mom(StabilityMethod, (zarray(z + 1) - zd)/L_MOD_RSL)

   !       psihatm_z(z) = psihatm_z(z + 1) + dz/2.*phimzp*(cm*EXP(-1.*c2*beta*(zarray(z + 1) - zd)/elm)) &  !Taylor's approximation for integral
   !                      /(zarray(z + 1) - zd)
   !       psihatm_z(z) = psihatm_z(z) + dz/2.*phimz*(cm*EXP(-1.*c2*beta*(zarray(z) - zd)/elm)) &
   !                      /(zarray(z) - zd)

   !    ENDDO

   ! end function cal_psihatm_z

   ! function cal_psihath_z(StabilityMethod, nz, zarray, L_MOD_RSL, zH_RSL, Lc, beta, zd, elm, Scc, f) result(psihath_z)

   !    ! calculate psi_hat for momentum
   !    ! TS, 23 Oct 2019
   !    implicit none
   !    integer, intent(in) :: StabilityMethod ! stability method
   !    integer, intent(in) :: nz ! number of vertical layers

   !    real(KIND(1D0)), DIMENSION(nz), intent(in) :: zarray ! height of interest [m]
   !    real(KIND(1D0)), intent(in) ::  zh_RSL ! canyon depth [m]
   !    real(KIND(1D0)), intent(in) ::  Lc ! height scale for bluff bodies [m]
   !    real(KIND(1D0)), intent(in) ::  beta ! parameter in RSL
   !    real(KIND(1D0)), intent(in) ::  Scc ! parameter in RSL
   !    real(KIND(1D0)), intent(in) ::  f ! parameter in RSL
   !    real(KIND(1D0)), intent(in) ::  L_MOD_RSL ! Obukhov length [m]
   !    real(KIND(1D0)), intent(in) ::  elm ! displacement height used in RSL
   !    real(KIND(1D0)), intent(in) ::zd ! displacement height used in RSL

   !    ! output
   !    real(KIND(1D0)), DIMENSION(nz) ::psihath_z ! psim_hat at height of interest

   !    ! internal variables
   !    ! real(KIND(1D0)) ::zp ! a height above z used for iterative calculations
   !    ! real(KIND(1D0)) ::phim_lc ! displacement height used in RSL
   !    real(KIND(1D0)) ::phihz ! displacement height used in RSL
   !    real(KIND(1D0)) ::phihzp ! displacement height used in RSL
   !    ! real(KIND(1D0)) ::psim_hat_zp ! displacement height used in RSL
   !    real(KIND(1D0)) ::xxh1 ! displacement height used in RSL
   !    real(KIND(1D0)) ::xxh1_2 ! displacement height used in RSL
   !    real(KIND(1D0)) ::dphih ! displacement height used in RSL
   !    real(KIND(1D0)) ::phi_hathZh ! displacement height used in RSL
   !    real(KIND(1D0)) ::ch ! displacement height used in RSL
   !    real(KIND(1D0)) ::c2h ! displacement height used in RSL
   !    REAL(KIND(1d0)), DIMENSION(nz):: dif

   !    REAL(KIND(1d0)), PARAMETER::kappa = 0.40
   !    REAL(KIND(1d0)), PARAMETER::dz = 0.1 !height step

   !    integer::z, idx_can

   !    psihath_z = 0.*zarray

   !    ! determine index at the canyon top
   !    DO z = 1, nz
   !       dif(z) = ABS(zarray(z) - Zh_RSL)
   !    ENDDO
   !    idx_can = MINLOC(dif, DIM=1)
   !    ! zarray(idx_can) = Zh_RSL

   !    ! calculate phihatM according to H&F '07 and H&F '08 for heat and humidity
   !    xxh1 = stab_phi_heat(StabilityMethod, (Zh_RSL - zd)/L_MOD_RSL)
   !    xxh1_2 = stab_phi_heat(StabilityMethod, (Zh_RSL - zd + 1.)/L_MOD_RSL)

   !    phi_hathZh = kappa*Scc/(2.*beta*xxh1)
   !    dphih = xxh1_2 - xxh1

   !    IF (phi_hathZh > 1.) THEN
   !       ! c2 = 0.5 ! more stable, but less correct
   !       c2h = 0.5
   !    ELSE
   !       ! c2 = (kappa*(3.-(2.*beta**2.*Lc/xxm1*dphi)))/(2.*beta*xxm1 - kappa)  ! if very unstable this might cause some high values of psihat_z
   !       c2h = (kappa*Scc*(2.+f - (dphih*2.*beta**2.*Lc/xxh1)))/(2.*beta*xxh1 - kappa*Scc)
   !    ENDIF
   !    ! cm = (1.-phi_hatmZh)*EXP(c2/2.)
   !    ch = (1.-phi_hathzh)*EXP(c2h/2.)

   !    DO z = nz - 1, idx_can - 1, -1
   !       phihz = stab_phi_heat(StabilityMethod, (zarray(z) - zd)/L_MOD_RSL)
   !       phihzp = stab_phi_heat(StabilityMethod, (zarray(z + 1) - zd)/L_MOD_RSL)

   !       psihath_z(z) = psihath_z(z + 1) + dz/2.*phihzp*(ch*EXP(-1.*c2h*beta*(zarray(z + 1) - zd)/elm)) &  !Taylor's approximation for integral
   !                      /(zarray(z + 1) - zd)
   !       psihath_z(z) = psihath_z(z) + dz/2.*phihz*(ch*EXP(-1.*c2h*beta*(zarray(z) - zd)/elm)) &
   !                      /(zarray(z) - zd)

   !    ENDDO

   ! end function cal_psihath_z

   FUNCTION cal_zd_RSL(zh_RSL, beta, Lc) RESULT(zd_RSL)

      REAL(KIND(1D0)), INTENT(in) ::  zh_RSL ! canyon depth [m]
      REAL(KIND(1D0)), INTENT(in) ::  Lc ! height scale for bluff bodies [m]
      REAL(KIND(1D0)), INTENT(in) ::  beta ! parameter in RSL

      ! output
      REAL(KIND(1D0)) ::zd_RSL ! zd used in RSL

      zd_RSL = Zh_RSL - (beta**2.)*Lc
      !correct negative values using rule of thumb, TS 24 Jun 2020
      ! if (zd_RSL < 0) zd_RSL = 0.7*Zh_RSL

   END FUNCTION cal_zd_RSL

   FUNCTION cal_z0_RSL(StabilityMethod, zH_RSL, zd_RSL, beta, L_MOD_RSL, Lc) RESULT(z0_RSL)
      ! calculate z0 iteratively
      ! TS, 23 Oct 2019
      IMPLICIT NONE
      INTEGER, INTENT(in) ::StabilityMethod
      REAL(KIND(1D0)), INTENT(in) ::  zH_RSL ! canyon depth [m]
      REAL(KIND(1D0)), INTENT(in) ::  zd_RSL ! displacement height [m]
      REAL(KIND(1D0)), INTENT(in) ::  L_MOD_RSL ! Monin Obukhov length[m]
      REAL(KIND(1D0)), INTENT(in) ::  Lc ! canyon length scale [m]
      REAL(KIND(1D0)), INTENT(in) ::  beta ! height scale for bluff bodies [m]

      ! output
      REAL(KIND(1D0)) ::z0_RSL

      ! internal variables
      REAL(KIND(1D0)) ::psimZh, psimz0, z0_RSL_x, psihatm_Zh
      REAL(KIND(1D0)) ::err
      INTEGER ::it

      REAL(KIND(1D0)), PARAMETER::kappa = 0.40
      ! REAL(KIND(1d0)), PARAMETER::r = 0.1
      ! REAL(KIND(1d0)), PARAMETER::a1 = 4., a2 = -0.1, a3 = 1.5, a4 = -1.

      psimZh = stab_psi_mom(StabilityMethod, (Zh_RSL - zd_RSL)/L_MOD_RSL)
      psihatm_Zh = cal_psim_hat(StabilityMethod, Zh_RSL, zh_RSL, L_MOD_RSL, beta, Lc)

      !first guess
      z0_RSL = 0.1*Zh_RSL
      err = 10.
      ! psimz0 = 0.5
      it = 1
      DO WHILE ((err > 0.001) .AND. (it < 10))
         z0_RSL_x = z0_RSL
         psimz0 = stab_psi_mom(StabilityMethod, z0_RSL_x/L_MOD_RSL)
         z0_RSL = (Zh_RSL - zd_RSL)*EXP(-1.*kappa/beta)*EXP(-1.*psimZh + psimz0)*EXP(psihatm_Zh)
         err = ABS(z0_RSL_x - z0_RSL)
         it = it + 1
      END DO

      ! set limit on z0_RSL for numeric stability
      z0_RSL = MERGE(z0_RSL, 1D-2, z0_RSL > 1D-2)

   END FUNCTION cal_z0_RSL

   SUBROUTINE RSL_cal_prms( &
      StabilityMethod, zh, L_MOD, sfr, FAI, &!input
      zH_RSL, L_MOD_RSL, Lc, beta, zd_RSL, z0_RSL, elm, Scc, f, PAI)!output

      IMPLICIT NONE
      INTEGER, INTENT(in) :: StabilityMethod ! stability method
      REAL(KIND(1D0)), INTENT(in) ::  zh ! canyon depth [m]
      REAL(KIND(1D0)), INTENT(in) ::  FAI ! frontal area index
      REAL(KIND(1D0)), INTENT(in) ::  L_MOD ! Obukhov length [m]
      REAL(KIND(1D0)), DIMENSION(nsurf), INTENT(in) ::  sfr ! land cover fractions

      ! output
      ! real(KIND(1D0)), intent(out) ::L_stab ! threshold for Obukhov length under stable conditions
      ! real(KIND(1D0)), intent(out) ::L_unstab ! threshold for Obukhov length under unstable conditions
      REAL(KIND(1D0)), INTENT(out) ::L_MOD_RSL ! Obukhov length used in RSL module with thresholds applied
      REAL(KIND(1D0)), INTENT(out) ::zH_RSL ! mean canyon height used in RSL module with thresholds applied
      ! real(KIND(1D0)), intent(out) ::Lc_stab ! threshold for penetration distance scale under stable conditions
      ! real(KIND(1D0)), intent(out) ::Lc_unstab ! threshold for penetration distance scale under unstable conditions
      REAL(KIND(1D0)), INTENT(out) ::Lc ! penetration distance scale for bluff bodies [m]
      REAL(KIND(1D0)), INTENT(out) ::beta ! psim_hat at height of interest
      REAL(KIND(1D0)), INTENT(out) ::zd_RSL ! displacement height to prescribe if necessary [m]
      REAL(KIND(1D0)), INTENT(out) ::z0_RSL ! roughness length [m]
      REAL(KIND(1D0)), INTENT(out) ::elm ! length scale used in RSL
      REAL(KIND(1D0)), INTENT(out) ::Scc ! parameter in RSL
      REAL(KIND(1D0)), INTENT(out) ::f ! parameter in RSL
      REAL(KIND(1D0)), INTENT(out) ::PAI ! plan area index inlcuding area of trees

      ! internal variables
      ! INTEGER ::it
      REAL(KIND(1D0)) ::sfr_tr
      ! real(KIND(1D0)) ::L_MOD_RSL_x
      ! real(KIND(1D0)) ::lc_x
      REAL(KIND(1D0)) ::lc_over_L
      ! real(KIND(1D0)) ::betaHF
      ! real(KIND(1D0)) ::betaNL

      REAL(KIND(1D0)), PARAMETER::planF_low = 1E-6
      REAL(KIND(1D0)), PARAMETER::kappa = 0.40
      ! REAL(KIND(1d0)), PARAMETER::z0m= 0.40
      REAL(KIND(1D0)), PARAMETER::r = 0.1
      REAL(KIND(1D0)), PARAMETER::a1 = 4., a2 = -0.1, a3 = 1.5, a4 = -1.
      REAL(KIND(1D0)), PARAMETER::Zh_min = 0.4! limit for minimum canyon height used in RSL module

      ! under stable conditions, set a threshold for L_MOD to avoid numerical issues. TS 28 Oct 2019
      ! L_MOD = merge(L_MOD, 300.d1, L_MOD < 300.)

      ! zH_RSL
      zH_RSL = MAX(zh, Zh_min)

      ! land cover fraction of bluff bodies
      PAI = SUM(sfr([BldgSurf, ConifSurf, DecidSurf]))
      ! set a threshold for sfr_zh to avoid numerical difficulties
      ! PAI = min(PAI, 0.8)

      ! land cover fraction of trees
      sfr_tr = SUM(sfr([ConifSurf, DecidSurf]))

      ! height scale for buildings !not used? why?
      ! Lc_build = (1.-sfr(BldgSurf))/FAI*Zh_RSL  ! Coceal and Belcher 2004 assuming Cd = 2

      ! height scale for tress
      ! Lc_tree = 1./(cd_tree*a_tree) ! not used? why?

      ! height scale for bluff bodies
      Lc = (1.-PAI)/FAI*Zh_RSL
      ! set a threshold of Lc to avoid numerical diffulties when FAI is too large (e.g., FAI>10)
      Lc = MERGE(Lc, 0.5*Zh_RSL, Lc > 0.5*Zh_RSL)

      ! a normalised scale with a physcially valid range between [-2,2] (Harman 2012, BLM)
      lc_over_L = Lc/L_MOD
      ! lc_over_L = lc/L_MOD_RSL_x
      IF (lc_over_L > 0) THEN
         lc_over_L = MIN(2., lc_over_L)
      ELSE
         lc_over_L = MAX(-2., lc_over_L)
      END IF
      ! correct L_MOD_RSL
      L_MOD_RSL = Lc/lc_over_L

      ! Step 2:
      ! Parameterise beta according to Harman 2012 with upper limit of 0.5
      beta = cal_beta_RSL(StabilityMethod, PAI, sfr_tr, lc_over_L)

      ! Schmidt number Harman and Finnigan 2008: assuming the same for heat and momemntum
      Scc = 0.5 + 0.3*TANH(2.*lc_over_L)
      f = 0.5*((1.+4.*r*Scc)**0.5) - 0.5

      zd_RSL = cal_zd_RSL(Zh_RSL, beta, lc)

      elm = cal_elm_RSL(beta, Lc)

      ! calculate z0 iteratively
      z0_RSL = cal_z0_RSL(StabilityMethod, zh_RSL, zd_RSL, beta, L_MOD_RSL, lc)

   END SUBROUTINE RSL_cal_prms

   FUNCTION cal_beta_RSL(StabilityMethod, PAI, sfr_tr, lc_over_L) RESULT(beta)
      ! Step 2:
      ! Parameterise beta according to Harman 2012 with upper limit of 0.5
      IMPLICIT NONE

      INTEGER, INTENT(in) :: StabilityMethod ! stability method
      REAL(KIND(1D0)), INTENT(in) :: PAI
      REAL(KIND(1D0)), INTENT(in) :: sfr_tr
      REAL(KIND(1D0)), INTENT(in) :: lc_over_L

      ! output
      REAL(KIND(1D0)):: beta

      ! internal use
      REAL(KIND(1D0)):: betaHF
      REAL(KIND(1D0)):: betaNL

      REAL(KIND(1D0)), PARAMETER :: kappa = 0.4
      REAL(KIND(1D0)), PARAMETER::a1 = 4., a2 = -0.1, a3 = 1.5, a4 = -1.
      ! real(KIND(1D0)) :: phim_hat
      ! real(KIND(1D0)) :: zd_RSL

      REAL(KIND(1D0)) :: betaN2
      ! INTEGER :: it
      ! real(KIND(1D0)) :: err
      ! real(KIND(1D0)) :: phim

      ! betaN for trees found to be 0.3 and for urban 0.4 linearly interpolate between the two using surface fractions
      ! betaN2 = 0.30 + (1.-sfr(ConifSurf) - sfr(ConifSurf))*0.1
      IF (PAI > 0) THEN
         betaN2 = 0.30*sfr_tr/PAI + (PAI - sfr_tr)/PAI*0.4
      ELSE
         betaN2 = 0.35
      END IF

      betaHF = cal_beta_lc(stabilityMethod, betaN2, lc_over_L)

      betaNL = cal_beta_lc(stabilityMethod, kappa/2., lc_over_L)

      IF (lc_over_L > a2) THEN
         beta = betaHF
      ELSE
         beta = betaNL + ((betaHF - betaNL)/(1.+a1*ABS(lc_over_L - a2)**a3))
      END IF

      IF (beta > 0.5) THEN
         beta = 0.5
      END IF

   END FUNCTION cal_beta_RSL

   FUNCTION cal_beta_lc(stabilityMethod, beta0, lc_over_l) RESULT(beta_x)
      ! TS, 03 Aug 2020:
      ! iterative determination of beta depending on Lc/L
      ! ref: eqn 10 & 11 in Harman (2012, BLM)
      IMPLICIT NONE
      INTEGER, INTENT(in) :: StabilityMethod
      REAL(KIND(1D0)), INTENT(in) :: beta0
      REAL(KIND(1D0)), INTENT(in) ::lc_over_l
      REAL(KIND(1D0)) :: beta_x

      REAL(KIND(1D0)) :: phim, err, beta_x0

      INTEGER::it

      it = 1
      phim = 1
      err = 1
      ! print *, '***********************'
      ! print *, 'beta0:', beta0
      ! print *, 'Lc/L_MOD:', lc_over_l
      DO WHILE ((err > 0.001) .AND. (it < 20))
         beta_x0 = beta0/phim
         phim = stab_phi_mom(StabilityMethod, (beta_x0**2)*lc_over_l)
         ! TODO: how to deal with neutral condition when phim=0? TS 05 Feb 2021
         ! here we use beta=0.35 as a temporary workaround but a better solution is still neded.
         beta_x = beta0/phim
         err = ABS(beta_x - beta_x0)
         ! print *, it, err, beta_x0, beta_x, phim, lc_over_l
         it = it + 1

      END DO
      ! print *, ''

   END FUNCTION cal_beta_lc

END MODULE rsl_module

