module ReadInstance
    using DelimitedFiles
    export read_instance

    #Insert the instance name in filename and the MSS solution in filename2
    function read_instance(filename, filename2)
        println("Reading instance...")
        data = readdlm(filename)

        # Parametros (first line from filename)
        nb_specialties = data[2, 1]
        nb_patients    = data[2, 2]
        nb_rooms       = data[2, 3]
        nb_days        = data[2, 4]
        nb_shifts      = data[2, 5]
        capacidade_OR  = data[2, 6]
        capacidade_PO  = data[2, 7]
        capacidade_ICU = data[2, 8]
        pac_esperados  = data[2, 9]
        cplx_esperada  = data[2,10] 
        patient_by_specialty = data[2, 11]

        # Parametros (air e bid matrix from filename)
        air = Array{Int64, 2}(undef, nb_specialties, nb_rooms)
        for i in 1:nb_specialties
            for r in 1:nb_rooms
                air[i, r] = data[4 + i, 1 + r]
            end
        end

        bid = Array{Int64, 2}(undef, nb_specialties, nb_days)
        idx = 6 + nb_specialties
        for i in 1:nb_specialties
            for d in 1:nb_days
                bid[i, d] = data[idx + i, 1 + d]
            end
        end

        # Parametros (reading the patients data from filename)
        cplx_map = Dict("BAI" => 1, "MED" => 3, "ALT" => 5) # Dicionário para converter string em inteiro
        cplx_paciente = Array{Int64, 1}(undef, nb_patients)
        tempo_espera = Array{Int64, 1}(undef, nb_patients)
        tempo_OR = Array{Float64, 1}(undef, nb_patients)
        desvio_OR = Array{Float64, 1}(undef, nb_patients)
        tempo_PO = Array{Int64, 1}(undef, nb_patients)
        desvio_PO = Array{Int64, 1}(undef, nb_patients)
        precisa_ICU = Array{Bool, 1}(undef, nb_patients)
        tempo_ICU = Array{Int64, 1}(undef, nb_patients)
        desvio_ICU = Array{Int64, 1}(undef, nb_patients)
        idx = 7+ 2*nb_specialties   # setting the index to the first patient data row
        for i in 1:nb_patients
            cplx_paciente[i] = cplx_map[data[idx + i, 2]]    # Consulta-se o valor no dicionário e retorna o inteiro correspondente
            tempo_espera[i] = data[idx + i, 3]
            tempo_OR[i]     = data[idx + i, 4]
            desvio_OR[i]    = data[idx + i, 5]
            tempo_PO[i]     = data[idx + i, 6]
            desvio_PO[i]    = data[idx + i, 7]
            precisa_ICU[i]  = data[idx + i, 8]
            tempo_ICU[i]    = data[idx + i, 9]
            desvio_ICU[i]   = data[idx + i, 10]
            # println("i: ", i)
        end

        # Print debug information - Check if the parameters are read correctly
        # print("Number of specialties: ", nb_specialties, "\n")
        # print("Number of patients: ", nb_patients, "\n")
        # print("Number of rooms: ", nb_rooms, "\n")
        # print("Number of days: ", nb_days, "\n")
        # print("Number of shifts: ", nb_shifts, "\n")
        # print("OR capacity: ", capacidade_OR, "\n")
        # print("PO capacity: ", capacidade_PO, "\n")
        # print("ICU capacity: ", capacidade_ICU, "\n")

        # Opening the MSS solution from filename2 and determining the specialties_map
        data = readdlm(filename2)  # Re-read the data to avoid any pointer issues
        specialties_map = Dict(
            "OMF" => 1, "DIG" => 2, "GEN" => 3, "PED" => 4, "PLA" => 5,
            "THO" => 6, "VAS" => 7, "CRT" => 8, "OBG" => 9, "MAS" => 10,
            "NEU" => 11, "ORT" => 12, "OTR" => 13, "URO" => 14, "PRI" => 15
        )
        
        # Determining the time slots for workdays and shifts - Creating the Uw vector for workdays and shifts and the MSS matrix for specialties, rooms, and time slots
        nb_works_shifts = 2
        is_workday(d) = mod1(d, 7) <= 5
        Uw = [ (d-1)*nb_shifts + s for d in 1:nb_days for s in 1:nb_works_shifts if is_workday(d) ]
        MSS = zeros(Int8, nb_specialties, nb_rooms, nb_shifts*nb_days)  # ou Bool: falses(nb_specialties, nb_rooms, nb_u)

        # Reading the MSS solution from filename2 and filling the MSS matrix
        for r in 1:nb_rooms # Número de Salas
            for s in 1:2    # Turnos de manhã e tarde
                row = 2 + (r-1)*2 + (s-1)   # Linha correspondente à sala r e turno s no arquivo de entrada
                for d in 1:nb_days
                    # Pulando os dias de fim de semana
                    if (d > 5 && d <= 7) || (d > 12) 
                        continue
                    end

                    # Determining the correct column index based on the day d and shift s
                    col = 0
                    if s == 1
                        if d < 7 col = (1 + d) end
                        if d > 7 col = (1 + (d - 2)) end
                    else
                        if d < 7 col = d end
                        if d > 7 col = (d - 2) end
                    end
                    
                    # Getting the specialty index from the specialties_map dictionary
                    j = get(specialties_map, data[row, col], nothing)
                    if j == nothing
                        continue
                    end
                    
                    # Calculating the time slot index u based on day d and shift s - Atribuindo ao vetor MSS a especialidade j, na sala r, no turno u
                    u = (d-1)*nb_shifts + s
                    MSS[j, r, u] = 1
                end
            end
        end

        # Gerando o output no terminal e retornando os parâmetros lidos
        print("Instance read successfully!\n")
        return desvio_OR, desvio_PO, desvio_ICU, nb_specialties, nb_patients, nb_rooms, nb_days, nb_shifts, capacidade_OR, capacidade_PO, capacidade_ICU, 
                patient_by_specialty, MSS, pac_esperados, cplx_esperada, air, bid, cplx_paciente, tempo_espera, tempo_OR, tempo_PO, precisa_ICU, tempo_ICU
    end

end