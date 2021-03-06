class ProgramRunsController < ApplicationController

	require 'csv'

	# new is going to be coming from the Chrome extension, so can't get the CSRF token.  in future should consider whether we should require some kind of authentication for this
	protect_from_forgery with: :null_session, :only =>[:new], raise: false

  #-------------------------

  def download()
    dataset = Dataset.find(params[:id])
    filename = gen_filename(dataset)
    respond_to do |format|
      format.csv render_csv(dataset, filename)
    end
  end

  def render_csv(dataset, filename)
    set_file_headers(filename)
    set_streaming_headers()

    response.status = 200

    #setting the body to an enumerator, rails will iterate this enumerator
    self.response_body = csv_lines(dataset)
  end

  def set_file_headers(file_name)
    headers["Content-Type"] = "text/csv"
    headers["Content-disposition"] = "attachment; filename=\"#{file_name}\""
  end

  def set_streaming_headers()
    #nginx doc: Setting this to "no" will allow unbuffered responses suitable for Comet and HTTP streaming applications
    headers['X-Accel-Buffering'] = 'no'
    headers["Cache-Control"] ||= "no-cache"
    headers.delete("Content-Length")
  end

  def csv_lines(dataset)
    Enumerator.new do |output|
      Dataset.batch_based_construction(dataset){ |row| 
        output << CSV.generate_line(row) 
      }
    end
  end

  def make_report(prog, timeLimit = nil)
    ProgramRun.batch_based_report(prog, timeLimit)
  end

#-------------------------

  def new
    prog_id = params[:program_id]
    runs_so_far = ProgramRun.where({program_id: prog_id}).count
    permitted = params.permit(:program_id, :name)
    permitted[:run_count] = runs_so_far
    run = ProgramRun.create(permitted)
    subrun = ProgramSubRun.create({program_run_id: run.id})
  	render json: { run_id: run.id, sub_run_id: subrun.id }
  end

  def new_sub_run
    run = ProgramRun.find(params[:program_run_id])
    subrun = ProgramSubRun.create({program_run_id: run.id})
    render json: { sub_run_id: subrun.id }
  end

  module Scraped
    TEXT = 1
    LINK = 2
  end

  def save_slice
    ProgramRun.save_slice_internals(params)
  	render json: { }
  end

  def update_run_name
    run = ProgramRun.find(params[:id])
    run.name = params[:name]
    run.save

    render json: {}
  end

  def gen_filename_for_prog(program)
      fn = program.name
      if (fn == nil or fn == "")
          fn = "dataset"
      end
      return fn
  end

  def render_rows(rows, filename)
    @rows = rows
    response.headers['Content-Type'] = 'text/csv'
    response.headers['Content-Disposition'] = 'attachment; filename=' + filename + '.csv'    
    render :template => "datasets/download.csv.erb"
  end

  #-------------------------

  def download_run
    run = ProgramRun.find(params[:id])
    filename = run.gen_filename()+".csv"
    respond_to do |format|
      format.csv {render_csv_helper(false, false, run, nil, filename, nil, nil)}
    end
  end

  def download_run_detailed
    run = ProgramRun.find(params[:id])
    filename = run.gen_filename()+".csv"
    respond_to do |format|
      format.csv {render_csv_helper(false, true, run, nil, filename, nil, nil)}
    end
  end

  def download_all_runs
    prog = Program.find(params[:id])
    timeLimit = nil
    rowLimit = nil
    detailed = false
    if (params[:hours])
      timeLimit = params[:hours]
    elsif (params[:rows])
      # for now you can have a time limit or a row limit, but not both; todo: do we want both?
      rowLimit = params[:rows]
    end
    if (params[:detailed])
      detailed = true
    end
    filename = gen_filename_for_prog(prog)+".csv"
    respond_to do |format|
      format.csv {render_csv_helper(true, detailed, nil, prog, filename, timeLimit, rowLimit)}
    end
  end

  def report
    prog = Program.find(params[:id])
    timeLimit = nil
    rowLimit = nil
    if (params[:hours])
      timeLimit = params[:hours]
    elsif (params[:rows])
      # for now you can have a time limit or a row limit, but not both; todo: do we want both?
      rowLimit = params[:rows]
    end
    reportdict = make_report(prog, timeLimit)
    render json: reportdict
  end

  def render_csv_helper(allRuns, detailed, run, prog, filename, timeLimit = nil, rowLimit = nil)
    set_file_headers(filename)
    set_streaming_headers()

    response.status = 200

    # setting the body to an enumerator, rails will iterate this enumerator
    self.response_body = csv_lines(allRuns, detailed, run, prog, timeLimit, rowLimit)
  end

  def set_file_headers(file_name)
    headers["Content-Type"] = "text/csv"
    headers["Content-disposition"] = "attachment; filename=\"#{file_name}\""
  end

  def set_streaming_headers()
    #nginx doc: Setting this to "no" will allow unbuffered responses suitable for Comet and HTTP streaming applications
    headers['X-Accel-Buffering'] = 'no'
    headers["Cache-Control"] ||= "no-cache"
    headers.delete("Content-Length")
  end

  def csv_lines(allRuns, detailed, run, prog, timeLimit = nil, rowLimit = nil)
    Enumerator.new do |output|
      ProgramRun.batch_based_construction(allRuns, detailed, run, prog, timeLimit, rowLimit){ |str| 
        output << str 
      }
    end
  end

#-------------------------

  def download_run_old
  	run = ProgramRun.find(params[:id])
    filename = run.gen_filename()
    outputrows = run.get_output_rows(false)
    render_rows(outputrows, filename)
  end

  def download_run_detailed_old
    run = ProgramRun.find(params[:id])
    filename = run.gen_filename()
    outputrows = run.get_output_rows(true)
    render_rows(outputrows, filename)
  end

  def download_all
    prog = Program.find(params[:id])
    filename = gen_filename_for_prog(prog)

    rows = DatasetRow.
      where({program_id: prog.id}).
      includes(:program_run, dataset_cells: [:dataset_value, :dataset_link]).
      order("program_runs.run_count ASC", run_row_index: :asc)

    outputrows = []
    currentRowIndex = -1
    currentProgRun = nil
    currentProgRunCounter = 0
    rows.each{ |row|
      outputrows.push([])
      currentRowIndex += 1
      if (currentProgRun != row.program_run_id)
        progRunObj = row.program_run
        currentProgRunCounter = progRunObj.run_count
        currentProgRun = row.program_run_id
      end

      cells = row.dataset_cells.order(col: :asc)
      cells.each{ |cell|

      if (cell.scraped_attribute == Scraped::TEXT)
        outputrows[currentRowIndex].push(cell.dataset_value.text)
      elsif (cell.scraped_attribute == Scraped::LINK)
        outputrows[currentRowIndex].push(cell.dataset_link.link)
      else
        # for now, default to putting the text in
        outputrows[currentRowIndex].push(cell.dataset_value.text)
      end
        
      }

      # and at the end of the row, go ahead and add the program_run_id to let the user know which pass produced the row
      outputrows[currentRowIndex].push(currentProgRunCounter)
    }
    render_rows(outputrows, filename)
  end

end
