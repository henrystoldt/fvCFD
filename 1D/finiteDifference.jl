include("constitutiveRelations.jl")
include("vectorFunctions.jl")

######################### CFL #######################
# 1D only
function CFL(U, T, dt, dx, gamma=1.4, R=287.05)
    return (abs(U[1]) + sqrt(gamma * R * T)) * dt / dx
end

######################### Gradient Computation #######################
function forwardGradient(dx, values...)
    result = []
    for vals in values
        n = size(vals,1)
        grad = Array{Float64, 1}(undef, n)
        grad[n] = 0
        for i in 1:n-1
            grad[i] = (vals[i+1] - vals[i]) / dx[i]
        end
        push!(result, grad)
    end
    return result
end

function backwardGradient(dx, values...)
    result = []
    for vals in values
        n = size(vals,1)
        grad = Array{Float64, 1}(undef, n)
        grad[1] = 0
        for i in 2:n
            grad[i] = (vals[i] - vals[i-1])/dx[i-1]
        end
        push!(result, grad)
    end
    return result
end

# Unused
function centralGradient(dx, values...)
    result = []
    for vals in values
        n = size(vals,1)
        grad = Array{Float64, 1}(undef, n)
        grad[1] = 0
        grad[n] = 0
        for i in 2:n-1
            grad[i] = (vals[i+1] - vals[i-1])/(dx[i] + dx[i-1])
        end
        push!(result, grad)
    end
    return result
end

# Unused
function upwindGradient(dx, U, values...)
    result = []
    for vals in values
        n = size(vals,1)
        grad = Array{Float64, 1}(undef, n)

        if U[1] > 0
            grad[1] = 0
        end
        if U[n] <= 0
            grad[n] = 0
        end

        for i in 1:n
            if U[i] > 0 && i > 1
                grad[i] = (vals[i] - vals[i-1])/dx[i-1]
            elseif U[i] == 0 && i > 1 && i < n
                grad[i] = (vals[i+1] - vals[i-1]) / (dx[i-1] + dx[i])
            elseif i < n
                grad[i] = (vals[i+1] - vals[i])/dx[i]
            end
        end
        push!(result, grad)
    end
    return result
end

# Just the numerator of the central second derivative, used for artificial diffusion term
function central2GradNum(dx, values...)
    result = []
    for vals in values
        n = size(vals,1)
        grad = Array{Float64, 1}(undef, n)
        grad[1] = 0
        grad[n] = 0
        for i in 2:n-1
            grad[i] = vals[i+1] - 2*vals[i] + vals[i-1]
        end
        push!(result, grad)
    end
    return result
end

# Denominator of artificial diffusion term
function central2GradDenom(dx, values...)
    result = []
    for vals in values
        n = size(vals,1)
        grad = Array{Float64, 1}(undef, n)
        grad[1] = 0
        grad[n] = 0
        for i in 2:n-1
            grad[i] = vals[i+1] + 2*vals[i] + vals[i-1]
        end
        push!(result, grad)
    end
    return result
end

######################### Solvers #######################
# Pass in initial values for each variable
# Shock Tube (undisturbed zero gradient) boundary conditions assumed

#TODO: Issue with shock position
# Non-conservative
function macCormack1DFDM(dx, P, T, U; initDt=0.001, endTime=0.14267, targetCFL=0.2, gamma=1.4, R=287.05, Cp=1005, Cx=0.3)
    nCells = size(dx, 1)

    rho = Array{Float64, 1}(undef, nCells)
    e = Array{Float64, 1}(undef, nCells)

    for i in 1:nCells
        rho[i] = idealGasRho(T[i], P[i])
        e[i] = calPerfectEnergy(T[i])
    end

    drhoPred = Array{Float64, 1}(undef, nCells)
    duPred = Array{Float64, 1}(undef, nCells)
    dePred = Array{Float64, 1}(undef, nCells)

    rhoPred = Array{Float64, 1}(undef, nCells)
    TPred = Array{Float64, 1}(undef, nCells)
    UPred = Array{Float64, 1}(undef, nCells)
    PPred = Array{Float64, 1}(undef, nCells)
    ePred = Array{Float64, 1}(undef, nCells)

    CFL = Array{Float64, 1}(undef, nCells)

    dt = initDt
    currTime = 0
    while currTime < endTime
        if (endTime - currTime) < dt
            dt = endTime - currTime
        end

        ############## Predictor #############
        drhodx, dudx, dpdx, dedx = backwardGradient(dx, rho, U, P, e)
        pCentralGrad, rhoCG, uCG, eCG = central2GradNum(dx, P, rho, U, e)
        pDenom = central2GradDenom(dx, P)[1]

        for i in 2:(nCells-1)
            # Eq. 6.1, 6.2, 6.4 (Checked)
            drhoPred[i] = -(rho[i]*dudx[i] + U[i]*drhodx[i])
            duPred[i] = -(U[i]*dudx[i] + dpdx[i]/rho[i])
            dePred[i] = -(U[i]*dedx[i] + P[i]*dudx[i]/rho[i])

            S = Cx * abs(pCentralGrad[i])/pDenom[i]
            rhoPred[i] = rho[i] + drhoPred[i]*dt + S*rhoCG[i]
            UPred[i] = U[i] + duPred[i]*dt + S*uCG[i]
            ePred[i] = e[i] + dePred[i]*dt + S*eCG[i]
            TPred[i] = calPerfectT(ePred[i])
            PPred[i] = idealGasP(rhoPred[i], TPred[i])
        end

        ############### Corrector ################
        drhodx, dudx, dpdx, dedx = forwardGradient(dx, rhoPred, UPred, PPred, ePred)
        pCentralGrad, rhoCG, uCG, eCG = central2GradNum(dx, PPred, rhoPred, UPred, ePred)
        pDenom = central2GradDenom(dx, PPred)[1]

        for i in 2:(nCells-1)
            drhoPred2 = -(rhoPred[i]*dudx[i] + UPred[i]*drhodx[i])
            duPred2 = -(UPred[i]*dudx[i] + dpdx[i]/rhoPred[i])
            dePred2 = -(UPred[i]*dedx[i] + PPred[i]*dudx[i]/rhoPred[i])

            # Perform timestep using average gradients
            S = Cx * abs(pCentralGrad[i])/pDenom[i]
            rho[i] += (drhoPred2 + drhoPred[i])*dt/2 + S*rhoCG[i]
            U[i] += (duPred2 + duPred[i])*dt/2 + S*uCG[i]
            e[i] += (dePred2 + dePred[i])*dt/2 + S*eCG[i]
            T[i] = calPerfectT(e[i])
            P[i] = idealGasP(rho[i], T[i])
        end

        ############### Boundaries ################
        # Waves never reach the boundaries, so boundary treatemnt doesn't need to be good
        allVars = [ rho, U, e, T, P ]
        copyValues(3, 2, allVars)
        copyValues(2, 1, allVars)
        copyValues(nCells-2, nCells-1, allVars)
        copyValues(nCells, nCells, allVars)

        ############## CFL Calculation, timestep adjustment #############
        for i in 1:nCells
            CFL[i] = (abs(U[i]) + sqrt(gamma * R * T[i])) * dt / dx[i]
        end
        maxCFL = maximum(CFL)

        # Adjust time step to slowly approach target CFL
        dt *= ((targetCFL/maxCFL - 1)/5+1)

        currTime += dt
    end

    return P, U, T, rho
end

function macCormack1DConservativeFDM(dx, P, T, U; initDt=0.001, endTime=0.14267, targetCFL=0.2, gamma=1.4, R=287.05, Cp=1005, Cx=0.3)
    nCells = size(dx, 1)

    rho = Array{Float64, 1}(undef, nCells)
    xMom = Array{Float64, 1}(undef, nCells)
    eV2 = Array{Float64, 1}(undef, nCells)
    rhoU2p = Array{Float64, 1}(undef, nCells)
    rhoUeV2PU = Array{Float64, 1}(undef, nCells)

    for i in 1:nCells
        rho[i], xMom[i], eV2[i] = encodePrimitives(P[i], T[i], U[i])
        rhoU2p[i] = xMom[i]*U[i] + P[i]
        rhoUeV2PU[i] = U[i]*eV2[i] + P[i]*U[i]
    end

    drhoP = Array{Float64, 1}(undef, nCells)
    dxMP = Array{Float64, 1}(undef, nCells)
    deV2P = Array{Float64, 1}(undef, nCells)

    xMomP = Array{Float64, 1}(undef, nCells)
    eV2P = Array{Float64, 1}(undef, nCells)
    rhoP = Array{Float64, 1}(undef, nCells)
    PP = Array{Float64, 1}(undef, nCells)
    rhoU2pP = Array{Float64, 1}(undef, nCells)
    rhoUeV2PUP = Array{Float64, 1}(undef, nCells)

    CFL = Array{Float64, 1}(undef, nCells)

    dt = initDt
    currTime = 0
    while currTime < endTime
        if (endTime - currTime) < dt
            dt = endTime - currTime
        end

        ############## Predictor #############
        dxMomdx, drhoU2pdx, drhoUeV2PU = forwardGradient(dx, xMom, rhoU2p, rhoUeV2PU)
        pCentralGrad, rhoCG, xMomCG, eV2CG = central2GradNum(dx, P, rho, xMom, eV2)
        pDenom = central2GradDenom(dx, P)[1]

        for i in 2:(nCells-1)
            # Eq. 2.99, 2.105, 2.106
            drhoP[i] = -dxMomdx[i]
            dxMP[i] = -drhoU2pdx[i]
            deV2P[i] = -drhoUeV2PU[i]

            # Predict
            S = Cx * abs(pCentralGrad[i]) / pDenom[i]
            rhoP[i] = rho[i] + drhoP[i]*dt + S*rhoCG[i]
            xMomP[i] = xMom[i] + dxMP[i]*dt + S*xMomCG[i]
            eV2P[i] = eV2[i] + deV2P[i]*dt + S*eV2CG[i]

            # Decode
            PP[i], TP, UP = decodePrimitives(rhoP[i], xMomP[i], eV2P[i])
            rhoU2pP[i] = xMomP[i]*UP + PP[i]
            rhoUeV2PUP[i] = UP*eV2P[i] + PP[i]*UP
        end

        ############### Corrector ################
        # Rearward differences to compute gradients
        dxMomdxP, drhoU2pdxP, drhoUeV2PUP = backwardGradient(dx, xMomP, rhoU2pP, rhoUeV2PUP)
        pCentralGradP, rhoCGP, xMomCGP, eV2CGP = central2GradNum(dx, PP, rhoP, xMomP, eV2P)
        pDenomP = central2GradDenom(dx, PP)[1]

        for i in 2:(nCells-1)
            drhoP2 = -dxMomdxP[i]
            dxMP2 = -drhoU2pdxP[i]
            deV2P2 = -drhoUeV2PUP[i]

            # Perform timestep using average gradients
            S = Cx * abs(pCentralGradP[i]) / pDenomP[i]
            rho[i] += (drhoP2 + drhoP[i])*dt/2 + S*rhoCGP[i]
            xMom[i] += (dxMP2 + dxMP[i])*dt/2 + S*xMomCGP[i]
            eV2[i] += (deV2P2 + deV2P[i])*dt/2 + S*eV2CGP[i]

            # Decode
            P[i], T[i], U[i] = decodePrimitives(rho[i], xMom[i], eV2[i])
            rhoU2p[i] = xMom[i]*U[i] + P[i]
            rhoUeV2PU[i] = U[i]*eV2[i] + P[i]*U[i]
        end

        ############### Boundaries ################
        # Waves never reach the boundaries, so boundary treatment doesn't need to be good
        allVars = [ rho, rhoU2p, rhoUeV2PU, xMom, eV2, U, P, T ]
        copyValues(3, 2, allVars)
        copyValues(2, 1, allVars)
        copyValues(nCells-2, nCells-1, allVars)
        copyValues(nCells-1, nCells, allVars)

        ############## CFL Calculation, timestep adjustment #############
        for i in 1:nCells
            CFL[i] = (abs(U[i]) + sqrt(gamma * R * T[i])) * dt / dx[i]
        end
        maxCFL = maximum(CFL)

        # Adjust time step to slowly approach target CFL
        dt *= ((targetCFL/maxCFL - 1)/5+1)

        currTime += dt
    end

    return P, U, T, rho
end

function upwind1DConservativeFDM(dx, P, T, U; initDt=0.001, endTime=0.14267, targetCFL=0.1, gamma=1.4, R=287.05, Cp=1005, Cx=0.3)
    nCells = size(dx, 1)

    rho = Array{Float64, 1}(undef, nCells)
    xMom = Array{Float64, 1}(undef, nCells)
    eV2 = Array{Float64, 1}(undef, nCells)
    rhoU2p = Array{Float64, 1}(undef, nCells)
    rhoUeV2PU = Array{Float64, 1}(undef, nCells)

    for i in 1:nCells
        rho[i], xMom[i], eV2[i] = encodePrimitives(P[i], T[i], U[i])
        rhoU2p[i] = xMom[i]*U[i] + P[i]
        rhoUeV2PU[i] = U[i]*eV2[i] + P[i]*U[i]
    end

    CFL = Array{Float64, 1}(undef, nCells)

    dt = initDt
    currTime = 0
    while currTime < endTime
        if (endTime - currTime) < dt
            dt = endTime - currTime
        end

        ############## Predictor #############
        dxMomdx, drhoU2pdx, drhoUeV2PU = upwindGradient(dx, U, xMom, rhoU2p, rhoUeV2PU)
        pCentralGrad, rhoCG, xMomCG, eV2CG = central2GradNum(dx, P, rho, xMom, eV2)
        pDenom = central2GradDenom(dx, P)[1]

        for i in 2:(nCells-1)
            S = Cx * abs(pCentralGrad[i]) / pDenom[i]
            rho[i] = rho[i] -dxMomdx[i]*dt + S*rhoCG[i]
            xMom[i] = xMom[i] -drhoU2pdx[i]*dt + S*xMomCG[i]
            eV2[i] = eV2[i] -drhoUeV2PU[i]*dt + S*eV2CG[i]

            # Decode
            P[i], T[i], U[i] = decodePrimitives(rho[i], xMom[i], eV2[i])
            rhoU2p[i] = xMom[i]*U[i] + P[i]
            rhoUeV2PU[i] = U[i]*eV2[i] + P[i]*U[i]
        end

        ############### Boundaries ################
        # Waves never reach the boundaries, so boundary treatment doesn't need to be good
        allVars = [ rho, rhoU2p, rhoUeV2PU, xMom, eV2, U, P, T ]
        copyValues(3, 2, allVars)
        copyValues(2, 1, allVars)
        copyValues(nCells-2, nCells-1, allVars)
        copyValues(nCells, nCells, allVars)

        ############## CFL Calculation, timestep adjustment #############
        for i in 1:nCells
            CFL[i] = (abs(U[i]) + sqrt(gamma * R * T[i])) * dt / dx[i]
        end
        maxCFL = maximum(CFL)

        # Adjust time step to slowly approach target CFL
        dt *= ((targetCFL/maxCFL - 1)/5+1)

        currTime += dt
    end

    return P, U, T, rho
end